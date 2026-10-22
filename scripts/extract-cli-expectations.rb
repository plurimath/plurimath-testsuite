#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/portable_yaml"
require "digest"
require "json"
require "open3"
require "yaml"
require_relative "lib/model_recipes"

module CliExpectations
  class Error < StandardError; end
  PATH = "spec/plurimath/cli_spec.rb"
  module_function

  def arguments(node)
    node.arguments&.arguments || []
  end

  def body(node)
    raise Error, "expected literal block" unless node.block.is_a?(Prism::BlockNode)

    node.block.body&.body || []
  end

  def plain(recipe)
    recipe = ModelRecipes.unwrap(recipe)
    case recipe.fetch("kind")
    when "literal" then recipe.fetch("value")
    when "array" then recipe.fetch("items").map { |item| plain(item) }
    else raise Error, "CLI values must be literal strings or arrays"
    end
  end

  def source(root, revision, path)
    raise Error, "invalid source path" unless path.start_with?("spec/") && !path.split("/").include?("..")

    text, status = Open3.capture2("git", "-C", root, "show", "#{revision}:#{path}")
    raise Error, "missing source #{path}" unless status.success?

    text
  end

  def extract(root, revision)
    raise Error, "expected source commit" unless /\A[0-9a-f]{40}\z/.match?(revision)

    text = source(root, revision, PATH)
    ast = Prism.parse(text)
    raise Error, "invalid source syntax" unless ast.success?

    group = ast.value.statements.body.find { |node| node.is_a?(Prism::CallNode) && node.name == :describe }
    raise Error, "unexpected CLI class" unless group && arguments(group).one? && ModelRecipes.constant_name(arguments(group).first) == "Plurimath::Cli"

    convert = body(group).fetch(0)
    raise Error, "unexpected CLI entry" unless convert.name == :describe && arguments(convert).first.unescaped == ".convert"

    contexts = body(convert)
    raise Error, "unexpected CLI groups" unless contexts.length == 4 && contexts.all? { |node| node.is_a?(Prism::CallNode) && node.name == :context }

    decoder = ModelRecipes::Decoder.new
    rows, replacements, files = [], [], [{ "path" => PATH, "sha256" => Digest::SHA256.hexdigest(text) }]
    contexts.drop(1).each_with_index do |context, index|
      bindings = {}
      nodes = body(context)
      nodes.select { |node| node.name == :let }.each do |binding|
        raise Error, "invalid CLI binding" unless body(binding).one?

        bindings[arguments(binding).first.unescaped] = decoder.emit_ast(body(binding).first, bindings: bindings)
      end
      examples = nodes.select { |node| node.name == :it }
      raise Error, "unexpected CLI example" unless examples.one? && nodes.all? { |node| %i[let it].include?(node.name) }

      statements = body(examples.first)
      statements[0...-1].each do |statement|
        raise Error, "unexpected CLI setup" unless statement.is_a?(Prism::LocalVariableWriteNode)

        bindings[statement.name.to_s] = decoder.emit_ast(statement.value, bindings: bindings)
      end
      assertion = statements.last
      unless assertion.is_a?(Prism::CallNode) && assertion.name == :to && arguments(assertion).one? && assertion.receiver.name == :expect
        raise Error, "unexpected CLI assertion"
      end
      matcher = arguments(assertion).first
      unless matcher.name == :to_stdout && arguments(matcher).empty? && matcher.receiver.name == :output && arguments(matcher.receiver).one?
        raise Error, "expected exact stdout matcher"
      end
      start = body(assertion.receiver)
      unless start.one? && start.first.name == :start && start.first.receiver.name == :described_class && arguments(start.first).one?
        raise Error, "unexpected CLI call boundary"
      end
      argv = plain(decoder.emit_ast(arguments(start.first).first, bindings: bindings))
      expected = plain(decoder.emit_ast(arguments(matcher.receiver).first, bindings: bindings))
      raise Error, "CLI values must be strings" unless argv.is_a?(Array) && argv.all? { |arg| arg.is_a?(String) } && expected.is_a?(String)

      row = { "id" => "cli-convert-#{index + 1}", "arguments" => argv, "stdout" => expected,
              "source" => { "path" => PATH, "line" => context.location.start_line,
                            "sha256" => Digest::SHA256.hexdigest(context.location.slice) } }
      if (offset = argv.index("-p"))
        file = argv.fetch(offset + 1)
        input = source(root, revision, file)
        row["input_file"] = { "path" => file, "content" => input }
        files << { "path" => file, "sha256" => Digest::SHA256.hexdigest(input) }
      end
      rows << row
      replacements << { "start" => context.location.start_offset, "length" => context.location.length,
                        "original" => context.location.slice,
                        "replacement" => "it_behaves_like \"shared CLI conversion\", #{row.fetch('id').inspect}" }
    end
    output = text.b.dup
    replacements.reverse_each { |entry| output[entry.fetch("start"), entry.fetch("length")] = entry.fetch("replacement").b }
    output = output.sub('require "spec_helper"', "require \"spec_helper\"\nrequire_relative \"../support/shared_cli_examples\"")
    [{ "schema" => "plurimath-fixtures/cli-conversions/1", "source" => { "revision" => revision, "files" => files }, "cases" => rows },
     { "path" => PATH, "source" => text, "output" => output.force_encoding(Encoding::UTF_8), "replacements" => replacements }]
  end
end

if $PROGRAM_NAME == __FILE__
  root, revision, output, manifest = ARGV
  abort "usage: #{$PROGRAM_NAME} RUBY_ROOT SOURCE_SHA OUTPUT_YAML MANIFEST_JSON" unless manifest
  data, proof = CliExpectations.extract(root, revision)
  File.write(output, PortableYaml.dump(data))
  File.write(manifest, JSON.pretty_generate(proof))
  puts "#{data.fetch('cases').length} authored CLI conversions"
end
