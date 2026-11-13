#!/usr/bin/env ruby
# frozen_string_literal: true

# Validates the unicode stage generations that carry stage-gem rows for the
# external UnicodeMath inputs of fixtures/unicode-expectations.yaml (written by
# scripts/generate-unicode-external.rb), beyond what scripts/validate-stages.rb
# checks for every generation.
#
#   ruby scripts/validate-unicode-external.rb [root] [--cases N]
#     [--generation N --executed FILE]
#
# For every unicode generation whose provenance has the umath-external-raw or
# umath-external-model producer:
#
# * the fixture is the file the producer names, with that sha256: the working
#   tree copy when its bytes match, else the blob at the recorded commit;
# * the fixture has N cases (675) with ids unicode-external-001 to -N and
#   indexes 1 to N in order, each input_sha256 matching its input, and the
#   upstream source the producer records;
# * each producer's rows are exactly one per fixture case, in fixture order,
#   id = fixture id + .raw or .model, input = the fixture lexeme without its
#   0/1 display flag, decimal "."; provenance lists the same ids;
# * both producers are present, with the same fixture, umath commit and
#   recorded selection (plain-scalar inputs, duplicate inputs), the upstream
#   reference and the original creator's notice, and that notice file holds
#   the MIT licence with its copyright line;
# * rows with the same input (the duplicate upstream inputs) have the same
#   expected outcome.
#
# With --generation N --executed FILE, FILE lists the row ids a consumer
# replayed from generation N (one per line); every external row id of that
# generation must be listed, and nothing else that is an external id. This is
# the expected-versus-executed check for consumers.
#
# Like validate-stages.rb it runs with plain `ruby`: no gems. Exit status 0
# when valid, 1 on a violation, 2 on a usage or git error.

require "digest"
require "json"
require "open3"
require "yaml"

module UnicodeExternal
  class Failure < StandardError; end

  GENERATOR_PATH = "scripts/generate-unicode-external.rb"
  FIXTURE_PATH = "fixtures/unicode-expectations.yaml"
  FIXTURE_SCHEMA = "plurimath-fixtures/unicode-expectations/1"
  TESTSUITE_REPOSITORY = "https://github.com/plurimath/plurimath-testsuite"
  CASES = 675
  GROUP_SIZE = 75
  DECIMAL = "."
  PREFIXES = { "0" => "inline", "1" => "block" }.freeze
  NOTICE_PATH = "LICENSES/UnicodeMathML-MIT.txt"
  NOTICE_LINES = ["MIT License", "Copyright (c) 2019 Noah Doersing"].freeze
  # The upstream data the fixture's inputs were copied from. Reference only:
  # no row is compared with it.
  UPSTREAM = {
    "repository" => "https://github.com/plurimath/unicodemath-tests",
    "commit" => "ac19358ebdd0044cafe769feb121a49aff3230c8",
    "path" => "unicodemath_tests.yaml",
    "sha256" => "1af5f6775afabf7fd7076f85c8378981334885a2d63005f2f6f734695c401c1d",
    "use" => "reference only; its MathML is not an oracle for these rows",
  }.freeze
  # Where unicodemath-tests took the inputs from, and under which licence.
  ORIGIN = {
    "repository" => "https://github.com/MurrayIII/UnicodeMathML",
    "commit" => "eee21af94f1ca15727a1f99f3cfa278d77c3127b",
    "path" => "dist/unicodemathml-integration.js",
    "license" => "MIT",
    "copyright" => "Copyright (c) 2019 Noah Doersing",
    "notice" => NOTICE_PATH,
  }.freeze
  BOUNDARIES = {
    "raw-tree" => { "producer" => "umath-external-raw", "suffix" => ".raw",
                    "prefix" => "raw-external-" },
    "typed-model" => { "producer" => "umath-external-model",
                       "suffix" => ".model", "prefix" => "model-external-" },
  }.freeze

  # One fixture case: its id, index, input lexeme, whether the lexeme was a
  # plain (unquoted) YAML scalar, and the fixture's input_sha256.
  Case = Struct.new(:id, :index, :lexeme, :plain, :input_sha256) do
    # The value a YAML loader gives the input; the fixture's input_sha256 is
    # the SHA-256 of its JSON text.
    def value
      plain ? YAML.safe_load(lexeme) : lexeme
    end

    def display
      PREFIXES.fetch(lexeme[0]) do
        raise Failure, "#{id}: input #{lexeme.inspect} has no 0/1 display flag"
      end
    end

    # The UnicodeMath text the stage gem is given.
    def input
      display
      lexeme[1..]
    end
  end

  # The fixture read as a YAML node tree, so each input keeps its lexeme (two
  # upstream inputs, 10 and 11.25, are plain YAML numbers).
  module Fixture
    module_function

    # [source block, [Case]]
    def read(bytes)
      root = YAML.parse(bytes.dup.force_encoding(Encoding::UTF_8)).root
      top = pairs(root)
      schema = scalar(top["schema"], "schema")
      unless schema == FIXTURE_SCHEMA
        raise Failure, "#{FIXTURE_PATH}: schema #{schema.inspect} != #{FIXTURE_SCHEMA}"
      end

      source = fetch(top, "source").to_ruby
      cases = fetch(top, "cases").children.map do |node|
        row = pairs(node)
        input = fetch(row, "input")
        raise Failure, "#{FIXTURE_PATH}: an input is not a scalar" unless input.is_a?(Psych::Nodes::Scalar)

        Case.new(scalar(row["id"], "id"), Integer(scalar(row["index"], "index"), 10), input.value,
                 input.plain && !input.quoted,
                 scalar(pairs(fetch(row, "source"))["input_sha256"], "input_sha256"))
      end
      [source, cases]
    end

    def fetch(pairs, key)
      pairs.fetch(key) { raise Failure, "#{FIXTURE_PATH}: no #{key}" }
    end

    def pairs(node)
      raise Failure, "#{FIXTURE_PATH}: expected a mapping" unless node.is_a?(Psych::Nodes::Mapping)

      node.children.each_slice(2).to_h { |k, v| [k.value, v] }
    end

    def scalar(node, name)
      raise Failure, "#{FIXTURE_PATH}: #{name} is not a scalar" unless node.is_a?(Psych::Nodes::Scalar)

      node.value
    end

    # Every rule the selection relies on. Returns the cases.
    def check(source, cases, count = CASES)
      input = source.fetch("input")
      UPSTREAM.each do |key, want|
        next if key == "use"

        got = input[key == "commit" ? "revision" : key]
        raise Failure, "#{FIXTURE_PATH}: source input #{key} #{got.inspect} != #{want.inspect}" unless got == want
      end
      raise Failure, "#{FIXTURE_PATH}: #{cases.size} cases, expected #{count}" unless cases.size == count

      cases.each_with_index do |c, i|
        id = format("unicode-external-%03d", i + 1)
        unless c.id == id && c.index == i + 1
          raise Failure, "#{FIXTURE_PATH}: case #{i + 1} is #{c.id} (index #{c.index}), expected #{id}"
        end

        digest = Digest::SHA256.hexdigest(JSON.generate(c.value))
        raise Failure, "#{c.id}: input_sha256 #{c.input_sha256} != #{digest}" unless digest == c.input_sha256

        c.input
      end
    end

    def duplicates(cases)
      cases.group_by(&:input).values.select { |g| g.size > 1 }.map { |g| g.map(&:id) }
    end
  end

  # The checks described at the top of this file, on a checkout at +root+.
  class Validator
    attr_reader :errors, :checked

    def initialize(root, cases: CASES)
      @root = File.expand_path(root)
      @cases = cases
      @errors = []
      @checked = {}
    end

    def run
      ledger = YAML.safe_load(read("generations/unicode.yaml"), aliases: false)
      ledger.fetch("entries").each do |entry|
        provenance = YAML.safe_load(read("#{entry['path']}/provenance.yaml"), aliases: false)
        producers = provenance.fetch("producers")
        names = BOUNDARIES.values.map { |b| b["producer"] }
        next if (producers.keys & names).empty?

        check_generation(entry, provenance)
      end
      @errors.empty?
    end

    # The external row ids of generation +number+, by boundary.
    def ids(number)
      @checked.fetch(number) { raise Failure, "generation #{number} has no external rows" }
    end

    private

    def read(relative)
      File.binread(File.join(@root, relative)).force_encoding(Encoding::UTF_8)
    rescue SystemCallError => e
      raise Failure, "#{relative}: #{e.message}"
    end

    def fail_with(where, message)
      @errors << "#{where}: #{message}"
    end

    def check_generation(entry, provenance)
      dir = entry["path"]
      producers = provenance["producers"]
      missing = BOUNDARIES.values.map { |b| b["producer"] } - producers.keys
      return fail_with(dir, "missing producer #{missing.join(', ')}") unless missing.empty?

      blocks = BOUNDARIES.to_h { |b, spec| [b, producers[spec["producer"]]] }
      return unless check_producers(dir, blocks)

      ref = blocks["raw-tree"]["inputs"].first
      bytes = fixture_bytes(dir, ref) or return
      source, cases = Fixture.read(bytes)
      Fixture.check(source, cases, @cases)
      check_selection(dir, blocks, cases)
      check_notice(dir)

      @checked[entry["generation"]] = BOUNDARIES.to_h do |boundary, spec|
        [boundary, check_rows(dir, provenance, boundary, spec, cases)]
      end
    rescue Failure => e
      fail_with(dir, e.message)
    end

    # Both producer blocks name the same single fixture input, the same umath
    # commit and the reference blocks this script knows.
    def check_producers(dir, blocks)
      ok = true
      blocks.each do |boundary, block|
        where = "#{dir}/provenance.yaml #{BOUNDARIES.dig(boundary, 'producer')}"
        inputs = block["inputs"]
        unless inputs.is_a?(Array) && inputs.size == 1 && inputs.first["path"] == FIXTURE_PATH &&
               inputs.first["repository"] == TESTSUITE_REPOSITORY
          ok = fail_with(where, "inputs must be exactly #{FIXTURE_PATH} of #{TESTSUITE_REPOSITORY}") && false
        end
        unless block["semantic_boundary"] == boundary
          ok = fail_with(where, "semantic_boundary #{block['semantic_boundary'].inspect} != #{boundary}") && false
        end
        unless block.dig("generator", "path") == GENERATOR_PATH
          ok = fail_with(where, "generator is not #{GENERATOR_PATH}") && false
        end
        config = block["configuration"] || {}
        { "upstream" => UPSTREAM, "origin" => ORIGIN }.each do |key, want|
          ok = fail_with(where, "configuration #{key} != #{want.inspect}") && false unless config[key] == want
        end
      end
      a, b = blocks.values
      %w[commit version].each do |key|
        ok = fail_with(dir, "the producers' #{key} differ") && false unless a[key] == b[key]
      end
      ok = fail_with(dir, "the producers name different fixtures") && false unless a["inputs"] == b["inputs"]
      ok
    end

    # The fixture bytes with the recorded sha256: the working tree copy, or
    # the blob at the recorded commit.
    def fixture_bytes(dir, ref)
      want = ref["sha256"]
      path = File.join(@root, FIXTURE_PATH)
      bytes = File.binread(path) if File.file?(path)
      return bytes if bytes && Digest::SHA256.hexdigest(bytes) == want

      out, _err, status = Open3.capture3("git", "-C", @root, "cat-file", "blob", "#{ref['commit']}:#{FIXTURE_PATH}",
                                         binmode: true)
      return out if status.success? && Digest::SHA256.hexdigest(out) == want

      fail_with(dir, "#{FIXTURE_PATH}: neither the working tree nor #{ref['commit']} has sha256 #{want}")
      nil
    end

    def check_selection(dir, blocks, cases)
      plain = cases.select(&:plain).map(&:id)
      duplicates = Fixture.duplicates(cases)
      blocks.each do |boundary, block|
        where = "#{dir}/provenance.yaml #{BOUNDARIES.dig(boundary, 'producer')}"
        selection = block.dig("configuration", "selection") || {}
        fail_with(where, "selection cases #{selection['cases'].inspect} != #{cases.size}") unless selection["cases"] == cases.size
        fail_with(where, "selection plain_scalar_inputs != #{plain.inspect}") unless selection["plain_scalar_inputs"] == plain
        unless selection["duplicate_inputs"] == duplicates
          fail_with(where, "selection duplicate_inputs != #{duplicates.inspect}")
        end
      end
    end

    def check_notice(dir)
      text = read(NOTICE_PATH)
      missing = NOTICE_LINES.reject { |line| text.include?(line) }
      fail_with(dir, "#{NOTICE_PATH} lacks #{missing.join(', ')}") unless missing.empty?
    rescue Failure => e
      fail_with(dir, e.message)
    end

    # The rows of one producer, in payload path order, against the fixture.
    def check_rows(dir, provenance, boundary, spec, cases)
      entries = provenance.fetch("payloads").select { |p| p["producer"] == spec["producer"] }
      want_paths = cases.each_slice(GROUP_SIZE).map do |slice|
        format("payloads/%s%03d-%03d.yaml", spec["prefix"], slice.first.index, slice.last.index)
      end
      unless entries.map { |e| e["path"] } == want_paths
        fail_with(dir, "#{spec['producer']} payloads #{entries.map { |e| e['path'] }.inspect} != #{want_paths.inspect}")
      end

      rows = entries.flat_map do |e|
        doc = YAML.safe_load(read("#{dir}/#{e['path']}"), aliases: false)
        fail_with("#{dir}/#{e['path']}", "boundary #{doc['boundary'].inspect} != #{boundary}") unless doc["boundary"] == boundary
        listed = doc.fetch("cases").map { |c| c["id"] }
        fail_with("#{dir}/#{e['path']}", "provenance rows differ from the file's ids") unless e["rows"] == listed
        doc.fetch("cases")
      end

      want_ids = cases.map { |c| "#{c.id}#{spec['suffix']}" }
      got_ids = rows.map { |r| r["id"] }
      if got_ids != want_ids
        missing = want_ids - got_ids
        extra = got_ids - want_ids
        fail_with(dir, "#{spec['producer']}: #{got_ids.size} rows for #{want_ids.size} cases; " \
                       "missing #{missing.first(5).inspect}, extra #{extra.first(5).inspect}" \
                       "#{' (order differs)' if missing.empty? && extra.empty?}")
        return want_ids
      end

      by_input = Hash.new { |h, k| h[k] = [] }
      rows.zip(cases).each do |row, c|
        where = "#{dir} #{row['id']}"
        fail_with(where, "input #{row['input'].inspect} != #{c.input.inspect}") unless row["input"] == { "str" => c.input }
        fail_with(where, "options #{row['options'].inspect}") unless row["options"] == { "decimal" => DECIMAL }
        by_input[c.input] << row
      end
      by_input.each_value do |same|
        next if same.map { |r| r["expected"] }.uniq.size == 1

        fail_with(dir, "#{same.map { |r| r['id'] }.join(', ')} have the same input but different outcomes")
      end
      want_ids
    end
  end

  module CLI
    module_function

    def run(argv)
      root = "."
      cases = CASES
      generation = executed = nil
      args = argv.dup
      until args.empty?
        arg = args.shift
        case arg
        when "--cases" then cases = Integer(args.shift, 10)
        when "--generation" then generation = Integer(args.shift, 10)
        when "--executed" then executed = args.shift
        when /\A-/ then return usage("unknown option #{arg}")
        else root = arg
        end
      end
      return usage("--generation and --executed go together") if generation.nil? ^ executed.nil?

      validator = Validator.new(root, cases: cases)
      validator.run
      check_executed(validator, generation, executed) if executed
      validator.errors.each { |e| warn "FAIL #{e}" }
      return 1 unless validator.errors.empty?
      return usage("no unicode generation has external rows") if validator.checked.empty?

      validator.checked.each do |number, ids|
        puts "ok generation #{number}: #{ids.map { |b, list| "#{list.size} #{b}" }.join(', ')} external rows"
      end
      0
    rescue Failure, ArgumentError, TypeError, Psych::Exception => e
      warn "validate-unicode-external: #{e.message}"
      2
    end

    def check_executed(validator, generation, path)
      expected = validator.ids(generation).values.flatten
      listed = File.readlines(path, chomp: true).map(&:strip).reject(&:empty?)
      external = listed.grep(/\Aunicode-external-/)
      missing = expected - external
      extra = external - expected
      dups = external.tally.select { |_, n| n > 1 }.keys
      validator.errors << "#{path}: #{missing.size} expected rows not executed, e.g. #{missing.first(5).inspect}" unless missing.empty?
      validator.errors << "#{path}: #{extra.size} unknown rows, e.g. #{extra.first(5).inspect}" unless extra.empty?
      validator.errors << "#{path}: rows executed twice: #{dups.first(5).inspect}" unless dups.empty?
      puts "ok #{path}: #{external.size} of #{expected.size} external rows executed" if validator.errors.empty?
    rescue SystemCallError => e
      validator.errors << "#{path}: #{e.message}"
    end

    def usage(message)
      warn "validate-unicode-external: #{message}"
      warn "usage: ruby scripts/validate-unicode-external.rb [root] [--cases N] [--generation N --executed FILE]"
      2
    end
  end
end

exit UnicodeExternal::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
