#!/usr/bin/env ruby
# frozen_string_literal: true

# Extract authored grammar observations without executing Ruby examples or
# measuring the implementation under test. Prism decodes Ruby string literals.
require_relative "lib/portable_yaml"
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "prism"
require "yaml"

module GrammarExpectations
  class Error < StandardError; end

  FORMATS = {
    "latex" => ["Plurimath::Latex::Parse", "formula"],
    "html" => ["Plurimath::Html::Parse", "formula"],
    "unicode_math" => ["Plurimath::UnicodeMath::Parse", "number"],
  }.freeze

  class Extractor
    attr_reader :manifest

    def initialize(repo:, revision:)
      raise Error, "source revision must be a full commit ID" unless /\A[0-9a-f]{40}\z/.match?(revision)

      @repo, @revision = repo, revision
      @manifest = []
    end

    def args(node)
      node.arguments&.arguments || []
    end

    def body(node)
      raise Error, "expected a literal block" unless node.block.is_a?(Prism::BlockNode)

      node.block.body&.body || []
    end

    def value(node)
      case node
      when Prism::StringNode then node.unescaped
      when Prism::InterpolatedStringNode
        unless node.parts.all? { |part| part.is_a?(Prism::StringNode) }
          raise Error, "dynamic grammar input interpolation"
        end
        node.parts.map(&:unescaped).join
      when Prism::SymbolNode then { "symbol" => node.unescaped }
      when Prism::IntegerNode then node.value
      when Prism::NilNode then nil
      else raise Error, "unsupported literal #{node.type} at #{node.location.start_line}"
      end
    end

    def name(node)
      return node.name.to_s if node.is_a?(Prism::LocalVariableReadNode)
      return node.name.to_s if node.is_a?(Prism::CallNode) && !node.receiver && args(node).empty? && !node.block

      raise Error, "expected a bound name at #{node.location.start_line}"
    end

    def path(node, aliases)
      if node.is_a?(Prism::CallNode) && node.name == :first && args(node).empty? && !node.block
        return path(node.receiver, aliases) + [{ "operation" => "first" }]
      end
      if node.is_a?(Prism::CallNode) && node.name == :[] && args(node).length == 1
        return path(node.receiver, aliases) + [value(args(node).first)]
      end

      aliases.fetch(name(node)) { raise Error, "unknown projection root #{name(node)}" }
    end

    def transforms(node)
      return [] if name_or_nil(node) == "string"
      unless node.is_a?(Prism::CallNode) && %i[squeeze gsub].include?(node.name)
        raise Error, "unsupported grammar input expression"
      end

      prior = transforms(node.receiver)
      parameters = args(node)
      if node.name == :squeeze && parameters.length == 1
        prior + [{ "kind" => "squeeze", "value" => value(parameters.first) }]
      elsif node.name == :gsub && parameters.length == 2
        pattern = parameters.first
        pattern = if pattern.is_a?(Prism::RegularExpressionNode)
                    unless pattern.unescaped == "\\s" && pattern.closing_loc.slice == "/"
                      raise Error, "only the original whitespace expression is supported"
                    end
                    { "kind" => "whitespace" }
                  else
                    { "kind" => "literal", "value" => value(pattern) }
                  end
        prior + [{ "kind" => "replace", "pattern" => pattern, "value" => value(parameters.last) }]
      else
        raise Error, "unsupported input transform arguments"
      end
    end

    def name_or_nil(node)
      name(node)
    rescue Error
      nil
    end

    def entrypoint(subject)
      expression = body(subject).then { |statements| statements.one? ? statements.first : nil }
      unless expression.is_a?(Prism::CallNode) && expression.name == :parse && args(expression).one?
        raise Error, "unsupported grammar subject"
      end
      receiver = expression.receiver
      rule = "expression"
      if receiver.is_a?(Prism::CallNode) && receiver.name == :number && args(receiver).empty?
        rule = "number"
        receiver = receiver.receiver
      end
      unless receiver.is_a?(Prism::CallNode) && receiver.name == :new &&
          name_or_nil(receiver.receiver) == "described_class" && args(receiver).empty?
        raise Error, "unsupported grammar receiver"
      end
      { "rule" => rule, "transforms" => transforms(args(expression).first) }
    end

    def locale(hook)
      # The two source hooks contain only with_configuration, locale assignment
      # and example.run. Reject any additional statement instead of dropping it.
      text = hook.location.slice.gsub(/\s+/, "")
      match = /\Aarounddo\|example\|Plurimath.with_configurationdo\|config\|config.locale=:(ar|fr|en)example.runendend\z/.match(text)
      raise Error, "unsupported grammar hook" unless match

      match[1]
    end

    def observations(example, root)
      aliases = { root => [] }
      checks = []
      body(example).each do |statement|
        if statement.is_a?(Prism::LocalVariableWriteNode)
          aliases[statement.name.to_s] = path(statement.value, aliases)
          checks << { "path" => aliases.fetch(statement.name.to_s), "comparison" => "read" }
          next
        end
        unless statement.is_a?(Prism::CallNode) && statement.name == :to && args(statement).one?
          raise Error, "unsupported grammar assertion at #{statement.location.start_line}"
        end
        expectation, matcher = statement.receiver, args(statement).first
        unless expectation.is_a?(Prism::CallNode) && expectation.name == :expect && !expectation.receiver &&
            matcher.is_a?(Prism::CallNode) && !matcher.receiver
          raise Error, "unsupported grammar expectation"
        end
        if expectation.block
          unless body(expectation).one? && name(body(expectation).first) == root &&
              matcher.name == :raise_error && args(matcher).one? &&
              args(matcher).first.location.slice == "Parslet::ParseFailed"
            raise Error, "unsupported grammar refusal"
          end
          checks << { "comparison" => "parse_failure" }
          next
        end
        raise Error, "expected exactly one observed projection" unless args(expectation).one?

        projection = path(args(expectation).first, aliases)
        case matcher.name
        when :eq
          raise Error, "expected one equality value" unless args(matcher).one?
          checks << { "path" => projection, "comparison" => "eq", "expected" => value(args(matcher).first) }
        when :be_nil
          raise Error, "unexpected nil matcher arguments" unless args(matcher).empty?
          checks << { "path" => projection, "comparison" => "nil" }
        else raise Error, "unsupported matcher #{matcher.name}"
        end
      end
      raise Error, "empty grammar observations" if checks.empty?
      if checks.any? { |check| check["comparison"] == "parse_failure" } && checks.length != 1
        raise Error, "refusal cannot be combined with successful observations"
      end
      checks
    end

    def walk(group, inherited, rows, source, source_path)
      statements = body(group)
      lets = statements.select { |node| node.is_a?(Prism::CallNode) && node.name == :let }
      examples = statements.select { |node| node.is_a?(Prism::CallNode) && node.name == :it }
      subjects = statements.select { |node| node.is_a?(Prism::CallNode) && node.name == :subject }
      raise Error, "multiple grammar subjects" if subjects.length > 1
      subject = subjects.first
      state = inherited.dup
      if subject
        unless args(subject).one? && value(args(subject).first) == { "symbol" => state.fetch("root") }
          raise Error, "grammar subject name differs from observation root"
        end
        state.merge!(entrypoint(subject))
      end
      hooks = statements.select { |node| node.is_a?(Prism::CallNode) && node.name == :around }
      raise Error, "multiple grammar hooks" if hooks.length > 1
      state["locale"] = locale(hooks.first) if hooks.one?
      lets.each do |binding|
        unless args(binding).one? && value(args(binding).first) == { "symbol" => "string" } && body(binding).one?
          raise Error, "unsupported grammar binding"
        end
        state["input"] = value(body(binding).first)
      end
      statements.each do |node|
        unless node.is_a?(Prism::CallNode) && %i[describe context let subject around it].include?(node.name)
          raise Error, "unclassified grammar statement at #{node.location.start_line}"
        end
      end
      examples.each do |example|
        raise Error, "missing grammar input/entrypoint" unless state.key?("input") && state.key?("rule")
        checks = observations(example, state.fetch("root"))
        row = state.reject { |key, _| key == "root" }.merge(
          "id" => "grammar-#{state.fetch('format')}-#{format('%03d', rows.length + 1)}",
          "label" => value(args(group).first),
          "source" => { "path" => source_path, "line" => example.location.start_line },
          "observations" => checks,
        )
        rows << row
        @manifest << { "source" => source_path, "line" => example.location.start_line,
                       "id" => row.fetch("id"),
                       "observations" => checks.count { |check| check.fetch("comparison") != "read" },
                       "example_sha256" => Digest::SHA256.hexdigest(example.location.slice) }
      end
      statements.select { |node| %i[describe context].include?(node.name) }.each do |child|
        walk(child, state, rows, source, source_path)
      end
    end

    def extract
      files, rows = [], []
      FORMATS.each do |directory, (klass, root)|
        path = "spec/plurimath/#{directory}/parse_spec.rb"
        source, status = Open3.capture2("git", "-C", @repo, "show", "#{@revision}:#{path}")
        raise Error, "cannot read pinned grammar source #{path}" unless status.success?
        parsed = Prism.parse(source)
        raise Error, "grammar source has syntax errors" unless parsed.success?
        parsed.value.statements.body.each do |statement|
          is_spec = statement.is_a?(Prism::CallNode) && statement.name == :describe &&
            statement.receiver&.location&.slice == "RSpec"
          is_require = statement.is_a?(Prism::CallNode) && statement.name == :require &&
            !statement.receiver && !statement.block && args(statement).one? &&
            args(statement).first.is_a?(Prism::StringNode) && args(statement).first.unescaped == "spec_helper"
          raise Error, "unclassified top-level grammar source" unless is_spec || is_require
        end
        groups = parsed.value.statements.body.select { |node| node.is_a?(Prism::CallNode) && node.name == :describe }
        unless groups.one? && args(groups.first).one? && groups.first.receiver&.location&.slice == "RSpec"
          raise Error, "expected one RSpec grammar root"
        end
        raise Error, "unexpected grammar class" unless args(groups.first).first.location.slice == klass

        files << { "path" => path, "sha256" => Digest::SHA256.hexdigest(source) }
        walk(groups.first, { "format" => directory == "unicode_math" ? "unicode" : directory,
                             "root" => root, "locale" => nil }, rows, source, path)
      end
      raise Error, "empty grammar extraction" if rows.empty?
      { "schema" => "plurimath-fixtures/grammar-expectations/1",
        "source" => { "repository" => "https://github.com/plurimath/plurimath", "revision" => @revision,
                      "files" => files }, "cases" => rows }
    end
  end

  def self.main(argv)
    options = { out: File.expand_path("../fixtures/grammar-expectations.yaml", __dir__) }
    OptionParser.new do |parser|
      parser.on("--ruby-repo PATH") { |value| options[:repo] = value }
      parser.on("--ruby-ref SHA") { |value| options[:revision] = value }
      parser.on("--out PATH") { |value| options[:out] = value }
      parser.on("--manifest PATH") { |value| options[:manifest] = value }
    end.parse!(argv)
    extractor = Extractor.new(repo: options.fetch(:repo), revision: options.fetch(:revision))
    payload = extractor.extract
    FileUtils.mkdir_p(File.dirname(options.fetch(:out)))
    # Remove object identity shared by inherited settings; fixtures forbid
    # aliases and carry values rather than a Ruby object graph.
    File.write(options.fetch(:out), PortableYaml.dump(payload))
    File.write(options[:manifest], JSON.pretty_generate(extractor.manifest)) if options[:manifest]
    puts "Extracted #{payload.fetch('cases').length} examples and #{extractor.manifest.sum { |row| row.fetch('observations') }} authored observations"
  end
end

GrammarExpectations.main(ARGV) if $PROGRAM_NAME == __FILE__
