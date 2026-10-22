#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/portable_yaml"
require "digest"
require "fileutils"
require "json"
require "open3"
require "yaml"
require_relative "lib/model_recipes"

# XML parser assertions not already selected from the canonical corpus.
# Inputs and authored constructor/render expectations come from pinned syntax.
module XmlExpectations
  class Error < StandardError; end
  FILES = ["spec/plurimath/mathml/parser_spec.rb",
           *[1, 2, 3, 4, 7].map { |number| "spec/plurimath/mathml/v3/section_#{number}_spec.rb" },
           "spec/plurimath/omml/parser_spec.rb"].freeze

  class Extractor
    attr_reader :manifests

    def initialize(root, revision)
      raise Error, "expected pinned source commit" unless /\A[0-9a-f]{40}\z/.match?(revision)

      @root, @revision = root, revision
      @sources, @cases, @ledger, @manifests = [], [], [], []
      @constants = ModelRecipes::Bindings.new
      @constants.add_source(source("spec/plurimath/fixtures/formula_modules/expected_values.rb"))
      @decoder = ModelRecipes::Decoder.new(constants: @constants)
    end

    def source(path)
      raise Error, "source path escapes repository" unless path.start_with?("spec/") && !path.split("/").include?("..")

      text, status = Open3.capture2("git", "-C", @root, "show", "#{@revision}:#{path}")
      raise Error, "missing pinned source #{path}" unless status.success?

      @sources << { "path" => path, "sha256" => Digest::SHA256.hexdigest(text) }
      text
    end

    def arguments(node)
      node.arguments&.arguments || []
    end

    def statements(node)
      raise Error, "expected a literal XML example block" unless node.block.is_a?(Prism::BlockNode)

      node.block.body&.body || []
    end

    def literal(node, bindings)
      recipe = ModelRecipes.unwrap(@decoder.emit_ast(node, bindings: bindings))
      raise Error, "XML input must be literal text" unless recipe["kind"] == "literal" && recipe["value"].is_a?(String)

      recipe.fetch("value")
    end

    def variable?(node, expected)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == expected.to_sym &&
        arguments(node).empty? && !node.block
    end

    def context?(node)
      node.is_a?(Prism::CallNode) && %i[describe context].include?(node.name) && node.block
    end

    def default_input(format, bindings)
      return literal(bindings.fetch("exp"), bindings) if format == "mathml"

      source(literal(bindings.fetch("file_name"), bindings))
    end

    def actual(node, bindings, format)
      method = nil
      if node.is_a?(Prism::CallNode) && %i[to_latex to_mathml to_omml to_asciimath to_html to_unicodemath].include?(node.name)
        raise Error, "unexpected XML render arguments" unless arguments(node).empty? && !node.block

        method, node = node.name.to_s, node.receiver
      end
      if variable?(node, "formula")
        return [default_input(format, bindings), method, "subject"]
      end
      unless node.is_a?(Prism::CallNode) && node.name == :parse && arguments(node).empty? && !node.block
        raise Error, "unsupported XML parser observation"
      end
      receiver = node.receiver
      unless receiver.is_a?(Prism::CallNode) && receiver.name == :new &&
          variable?(receiver.receiver, "described_class") && arguments(receiver).one? && !receiver.block
        raise Error, "unsupported XML parser constructor"
      end
      [literal(arguments(receiver).first, bindings), method, "parse-#{node.location.start_offset}"]
    end

    def example(node, bindings, format, path, context, suffix = "")
      locals = bindings.dup
      sequence = []
      count = 0
      statements(node).each do |statement|
        if statement.is_a?(Prism::LocalVariableWriteNode)
          # Preserve every local's authored constructor/literal work, and fail
          # closed rather than discarding an unrecognized setup operation.
          @decoder.emit_ast(statement.value, bindings: locals)
          locals[statement.name.to_s] = statement.value
          next
        end
        unless statement.is_a?(Prism::CallNode) && statement.name == :to && arguments(statement).one?
          raise Error, "unsupported XML example statement"
        end
        expect = statement.receiver
        matcher = arguments(statement).first
        unless expect.is_a?(Prism::CallNode) && expect.name == :expect && !expect.receiver && !expect.block &&
            arguments(expect).one? && matcher.is_a?(Prism::CallNode) && %i[eq include].include?(matcher.name) &&
            !matcher.receiver && arguments(matcher).one? && !matcher.block
          raise Error, "unsupported XML matcher"
        end
        input, method, parse_id = actual(arguments(expect).first, locals, format)
        raise Error, "contains matcher requires a render observation" if matcher.name == :include && !method
        expected = @decoder.emit_ast(arguments(matcher).first, bindings: locals)
        kind = method ? (matcher.name == :include ? "render_include" : "render_equal") : "model_equal"
        raw = ModelRecipes.unwrap(expected)
        unless method ? raw["kind"] == "literal" && raw["value"].is_a?(String) : raw["kind"] == "constructor"
          raise Error, "XML expectation is not an authored model or text"
        end
        observation = { "kind" => kind, "expected" => expected }
        observation["method"] = method if method
        step = sequence.find { |entry| entry.fetch("parse_id") == parse_id }
        unless step
          step = { "parse_id" => parse_id, "input" => input, "input_transform" => "identity", "observations" => [] }
          sequence << step
        end
        raise Error, "a parser identity changed input" unless step.fetch("input") == input

        step.fetch("observations") << observation
        count += 1
      end
      raise Error, "empty XML example" if sequence.empty?

      id = "#{format}-authored-#{File.basename(path, '_spec.rb').tr('_', '-')}-#{node.location.start_line}#{suffix}"
      @cases << { "id" => id, "input_format" => format,
                  "parser_class" => format == "mathml" ? "Mathml::Parser" : "Omml::Parser",
                  "input" => sequence.first.fetch("input"), "input_transform" => "identity", "configuration" => {},
                  "sequence" => sequence,
                  "source" => { "file" => path, "line" => node.location.start_line,
                                "context_sha256" => Digest::SHA256.hexdigest(context.location.slice) } }
      @ledger << { "file" => path, "line" => node.location.start_line, "status" => "exported",
                   "case_id" => id, "assertion_sites" => count,
                   "context_sha256" => Digest::SHA256.hexdigest(context.location.slice) }
      id
    end

    def extract
      FILES.each do |path|
        text = source(path)
        parsed = Prism.parse(text)
        raise Error, "XML source syntax error" unless parsed.success?

        format = path.include?("/omml/") ? "omml" : "mathml"
        root = parsed.value.statements.body.find { |node| context?(node) }
        expected_class = format == "mathml" ? "Plurimath::Mathml::Parser" : "Plurimath::Omml::Parser"
        unless root && arguments(root).one? && ModelRecipes.constant_name(arguments(root).first) == expected_class
          raise Error, "XML parser class differs"
        end
        if statements(root).all? { |node| node.is_a?(Prism::CallNode) && node.name == :it_behaves_like }
          @manifests << { "path" => path, "source_sha256" => Digest::SHA256.hexdigest(text),
                          "source" => text, "output" => text, "replacements" => [] }
          next
        end
        subject = statements(root).find { |node| node.is_a?(Prism::CallNode) && node.name == :subject }
        expected_subject = format == "mathml" ? "described_class.new(exp).parse" : "described_class.new(File.read(file_name)).parse"
        unless subject && statements(subject).one? && statements(subject).first.location.slice.gsub(/\s+/, "") == expected_subject
          raise Error, "#{path}: XML subject differs: #{subject&.location&.slice.inspect}"
        end
        replacements = []
        statements(root).each do |context|
          next if context.is_a?(Prism::CallNode) && %i[subject it_behaves_like].include?(context.name)
          raise Error, "unclassified XML root statement" unless context?(context)

          bindings = {}
          statements(context).each do |statement|
            next unless statement.is_a?(Prism::CallNode) && statement.name == :let
            names = arguments(statement)
            raise Error, "unexpected XML let" unless names.one? && names.first.is_a?(Prism::SymbolNode) && statements(statement).one?

            bindings[names.first.unescaped] = statements(statement).first
          end
          examples = statements(context).select { |node| node.is_a?(Prism::CallNode) && node.name == :it }
          # Validate all declarations, including ones an assertion does not use.
          bindings.each_value { |expression| @decoder.emit_ast(expression, bindings: bindings) }
          if !examples.empty? && examples.length + bindings.length == statements(context).length
            ids = examples.map { |node| example(node, bindings, format, path, context) }
          else
            nodes = statements(context)
            loop = nodes.first
            unless nodes.one? && loop.is_a?(Prism::CallNode) && loop.name == :each &&
                loop.receiver.is_a?(Prism::HashNode) && arguments(loop).empty?
              raise Error, "#{path}:#{context.location.start_line}: unclassified XML context operations"
            end
            parameters = loop.block&.parameters&.parameters
            required = parameters&.requireds || []
            unless required.length == 2 && parameters.compact_child_nodes == required &&
                statements(loop).all? { |node| node.is_a?(Prism::CallNode) && node.name == :it }
              raise Error, "unsupported XML literal iteration"
            end
            map = ModelRecipes.unwrap(@decoder.emit_ast(loop.receiver))
            raise Error, "XML iteration must be an authored map" unless map.fetch("kind") == "map"
            ids = map.fetch("entries").each_with_index.flat_map do |entry, index|
              iteration = bindings.merge(required.first.name.to_s => entry.fetch("key"),
                                         required.last.name.to_s => entry.fetch("value"))
              statements(loop).map do |node|
                example(node, iteration, format, path, context, "-iteration-#{index + 1}")
              end
            end
          end
          replacement = ids.map do |id|
            "it_behaves_like \"shared parser constructor expectation\", #{id.inspect}, \"xml-parser-expectations\""
          end.join("\n  ")
          replacements << { "start" => context.location.start_offset, "length" => context.location.length,
                            "original" => context.location.slice, "replacement" => replacement }
        end
        output = text.b.dup
        replacements.reverse_each do |entry|
          output[entry.fetch("start"), entry.fetch("length")] = entry.fetch("replacement").b
        end
        relative = "../" * (path.count("/") - 1) + "support/shared_parser_examples"
        require_line = "require_relative #{relative.inspect}"
        output = output.sub('require "spec_helper"', "require \"spec_helper\"\n#{require_line}") unless output.include?(require_line)
        if format == "omml"
          output = output.sub('require "plurimath/fixtures/formula_modules/expected_values"' + "\n", "")
          output = output.sub("  subject(:formula) do\n    described_class.new(File.read(file_name)).parse\n  end\n\n", "")
        end
        @manifests << { "path" => path, "source_sha256" => Digest::SHA256.hexdigest(text),
                        "source" => text, "output" => output.force_encoding(Encoding::UTF_8), "replacements" => replacements }
      end
      raise Error, "empty XML extraction" if @cases.empty?
      ids = @cases.map { |row| row.fetch("id") }
      raise Error, "duplicate XML case IDs" unless ids.uniq.length == ids.length

      { "schema" => "plurimath-fixtures/xml-parser-expectations/1",
        "source" => { "revision" => @revision, "files" => @sources.uniq },
        "cases" => @cases, "ledger" => @ledger }
    end
  end

  def self.main(argv)
    root, revision, output, manifest = argv
    abort "usage: #{$PROGRAM_NAME} RUBY_ROOT PINNED_SHA OUTPUT_YAML MANIFEST_JSON" unless root && revision && output && manifest

    extractor = Extractor.new(root, revision)
    payload = extractor.extract
    FileUtils.mkdir_p(File.dirname(output))
    File.write(output, PortableYaml.dump(payload))
    File.write(manifest, JSON.pretty_generate(extractor.manifests))
    puts "#{payload.fetch('cases').length} XML examples, #{payload.fetch('ledger').sum { |row| row.fetch('assertion_sites') }} authored assertions"
  end
end

XmlExpectations.main(ARGV) if $PROGRAM_NAME == __FILE__
