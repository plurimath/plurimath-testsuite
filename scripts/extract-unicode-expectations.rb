# frozen_string_literal: true

# Static export of authored external UnicodeMath trees and constructor recipes.
# Does not load specs, model fixtures, or the implementation, and never parses math.
require_relative "lib/portable_yaml"
require "digest"
require "json"
require "open3"
require "yaml"
require_relative "lib/model_recipes"

module UnicodeExpectations
  REVISION = "a6bac8dcf76af4347eb93fa2a7289eb278dd3ffa"
  INPUT_REVISION = "ac19358ebdd0044cafe769feb121a49aff3230c8"
  PREFIX = "spec/plurimath/unicode_math/plurimath/"
  SPECS = {
    "raw" => ["#{PREFIX}unicodemath_tests_spec.rb", "UnicodeMathParseValues", "458c3afa177b0a319d88bfcbec3c7b597593cbdacfb3ca0736be20b7b097cae4"],
    "model" => ["#{PREFIX}unicodemath_transform_spec.rb", "UnicodeMathTransformValues", "53e0c5a6ba05754330d29df5c353f2762f1473eed1885a890661019b3a6acdf7"],
  }.freeze
  HELPER_SHA256 = "eb75e656a16261c269b82f0c4f57f40641de59cae67a5d22f547647d266a8c7a"
  SKIPPED = [33, 210, 211, 598, 599, 600, 601].freeze
  BOUNDARIES = {
    "raw" => { "class" => "UnicodeMath::Parse", "input" => "unicode_encode_entities", "output" => "post_processing" },
    "model" => { "class" => "UnicodeMath::Parser", "input" => "remove_prefix", "output" => "identity" },
  }.freeze

  class Extractor
    def initialize(root:, input_root:, revision: REVISION, input_revision: INPUT_REVISION)
      @root, @input_root, @revision, @input_revision = root, input_root, revision, input_revision
      @sources, @specs, @rewrites = [], {}, {}
    end

    def read(root, revision, path)
      source, status = Open3.capture2("git", "-C", root, "show", "#{revision}:#{path}")
      raise ModelRecipes::Unsupported, "missing pinned #{path}" unless status.success?

      source
    end

    def digest(source)
      Digest::SHA256.hexdigest(source)
    end

    def calls(node)
      [node, *node.compact_child_nodes.flat_map { |child| calls(child) }].grep(Prism::CallNode)
    end

    def extract
      # These complete audited source hashes pin the subject, loop, refusal matcher,
      # helpers and label behavior together. Changed scaffolds require a new audit.
      helper = read(@root, @revision, "spec/spec_helper.rb")
      raise ModelRecipes::Unsupported, "Unicode helper contract changed" unless digest(helper) == HELPER_SHA256
      @sources << { "path" => "spec/spec_helper.rb", "sha256" => digest(helper) }
      constants = ModelRecipes::Bindings.new
      expected = {}
      SPECS.each do |boundary, (path, namespace, sha256)|
        source = read(@root, @revision, path)
        raise ModelRecipes::Unsupported, "#{path}: audited scaffold changed" unless digest(source) == sha256
        parsed = Prism.parse(source)
        raise ModelRecipes::Unsupported, "invalid source #{path}" unless parsed.success?
        loops = calls(parsed.value).select { |call| call.name == :with_index && call.receiver&.location&.slice == "unicodemath_tests.each" }
        raise ModelRecipes::Unsupported, "expected exactly one external loop" unless loops.length == 1
        loop_node = loops.first
        @specs[boundary] = { "file" => path, "line" => loop_node.location.start_line, "sha256" => digest(loop_node.location.slice) }
        @rewrites[path] = [source, loop_node.location.start_offset, loop_node.location.length, boundary]
        @sources << { "path" => path, "sha256" => digest(source) }
        values_path = "spec/plurimath/fixtures/formula_modules/#{boundary == 'raw' ? 'unicode_math_parse_values' : 'unicode_math_transform_values'}.rb"
        values = read(@root, @revision, values_path)
        constants.add_source(values)
        @sources << { "path" => values_path, "sha256" => digest(values) }
        expected[boundary] = [namespace, values_path]
      end
      input_path = "unicodemath_tests.yaml"
      input_source = read(@input_root, @input_revision, input_path)
      inputs = YAML.safe_load(input_source, permitted_classes: [Time], aliases: false).fetch("tests")
      raise ModelRecipes::Unsupported, "expected 675 external rows" unless inputs.is_a?(Array) && inputs.length == 675
      decoder = ModelRecipes::Decoder.new(constants: constants)
      cases = inputs.each_with_index.map do |input, offset|
        index = offset + 1
        text = input.fetch("unicodemath")
        raise ModelRecipes::Unsupported, "external input must be text or number" unless text.is_a?(String) || text.is_a?(Integer) || text.is_a?(Float) && text.finite?
        provenance, recipes = {}, {}
        expected.each do |boundary, (namespace, values_path)|
          node = constants.resolve("#{namespace}::EXAMPLE_#{index}")
          recipes[boundary] = decoder.emit_ast(node)
          kind = ModelRecipes.unwrap(recipes.fetch(boundary)).fetch("kind")
          wanted = boundary == "raw" ? "map" : "constructor"
          raise ModelRecipes::Unsupported, "#{boundary} expectation must be #{wanted}" unless kind == wanted
          provenance[boundary] = { "file" => values_path, "constant" => "#{namespace}::EXAMPLE_#{index}", "line" => node.location.start_line, "sha256" => digest(node.location.slice) }
        end
        outcome = if SKIPPED.include?(index)
                    { "kind" => "parse_error", "category" => "parse_error", "message_pattern" => { "source" => "Expected one of \\[", "options" => [] } }
                  else
                    { "kind" => "equal" }
                  end
        { "id" => "unicode-external-#{index.to_s.rjust(3, '0')}", "index" => index,
          "input" => text, "outcome" => outcome, "expected" => recipes,
          "source" => { "input_index" => index, "input_sha256" => digest(JSON.generate(text)), "expected" => provenance } }
      end
      raise ModelRecipes::Unsupported, "duplicate IDs" unless cases.map { |row| row.fetch("id") }.uniq.length == 675
      { "schema" => "plurimath-fixtures/unicode-expectations/1", "source" => { "revision" => @revision, "files" => @sources,
          "input" => { "repository" => "https://github.com/plurimath/unicodemath-tests", "revision" => @input_revision, "path" => input_path, "sha256" => digest(input_source) } },
        "boundaries" => BOUNDARIES, "cases" => cases, "ledger" => @specs }
    end

    def rewritten_sources
      @rewrites.to_h do |path, (original, start, length, boundary)|
        output = original.b.dup
        output[start, length] = "it_behaves_like \"shared Unicode external expectations\", #{boundary.inspect}".b
        output = output.sub('require "yaml"', 'require_relative "../../../support/shared_unicode_examples"')
        output = output.lines.reject { |line| line.start_with?('require "plurimath/fixtures/formula_modules/unicode_math_') }.join
        [path, output]
      end
    end

    def rewrite!
      outputs = rewritten_sources
      outputs.each do |path, output|
        current = File.binread(File.join(@root, path))
        original = @rewrites.fetch(path).first.b
        raise ModelRecipes::Unsupported, "#{path}: refusing unrelated source change" unless [original, output].include?(current)
      end
      outputs.each { |path, output| File.binwrite(File.join(@root, path), output) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root, input_root, output = ARGV.shift(3)
  abort "usage: extract-unicode-expectations.rb GEM_ROOT INPUT_ROOT OUTPUT [--rewrite]" unless root && input_root && output
  rewrite = ARGV.delete("--rewrite")
  abort "unexpected arguments" unless ARGV.empty?
  extractor = UnicodeExpectations::Extractor.new(root: root, input_root: input_root)
  data = extractor.extract
  File.write(output, PortableYaml.dump(data, line_width: -1))
  extractor.rewrite! if rewrite
  puts JSON.generate(cases: data.fetch("cases").length, raw_trees: data.fetch("cases").length, model_recipes: data.fetch("cases").length,
                     refusal_rows: data.fetch("cases").count { |row| row.dig("outcome", "kind") == "parse_error" })
end
