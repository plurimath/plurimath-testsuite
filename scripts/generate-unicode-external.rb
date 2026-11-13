# frozen_string_literal: true

# Writes the next unicode stage generation with stage-gem rows for the 675
# external UnicodeMath inputs of fixtures/unicode-expectations.yaml: every
# payload of the latest unicode generation copied byte for byte, plus
# raw-external-<first>-<last>.yaml (Umath::RawParser raw tree) and
# model-external-<first>-<last>.yaml (Umath.parse typed model) payloads with
# one row per fixture case.
#
#   BUNDLE_GEMFILE=UMATH/Gemfile bundle exec ruby \
#     scripts/generate-unicode-external.rb --umath UMATH --out OUT \
#     [--jobs N] [--checkpoint FILE]
#
# UMATH is a clean plurimath/umath checkout. The outcome of each input is
# computed by that checkout's own scripts/stage_cases.rb (StageCases::Outcome,
# the frozen stage producer that wrote the earlier raw-tree and typed-model
# rows), on the Ruby and the native engine; the run fails unless both agree.
# This script only selects the inputs, groups the rows and writes provenance.
#
# Input selection. Every fixture case is used, in fixture order, and keeps
# its id: row ids are "<fixture id>.raw" and "<fixture id>.model". The
# fixture's input is the upstream unicodemath-tests lexeme, whose first
# character is a display flag ("0" inline, "1" block) and not UnicodeMath; it
# is removed (the fixture's model boundary, remove_prefix), and the rest is
# given to the stage gem unchanged. The raw-tree rows record Umath::RawParser's
# own preprocessing; that is not the plurimath spec helper
# unicode_encode_entities the fixture's raw expectations went through, and the
# typed model is Umath::Model::Document, not the fixture's Math::Formula. The
# fixture's expectations and the upstream MathML stay where they are, as
# references; nothing here compares against them.
#
# The fixture is read as a YAML node tree so that each input keeps its
# lexeme: two upstream inputs (10 and 11.25) are plain YAML numbers.
#
# This checkout must be clean for this script, the fixture and stages/ and
# generations/, so the recorded commit is the one that ran.
#
# Exit status: 0 on success, 1 on any failure.

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "yaml"
require "English"

require_relative "validate-unicode-external"

module UnicodeExternal
  ROOT = File.expand_path("..", __dir__)

  module Git
    module_function

    def call(*args)
      out, err, status = Open3.capture3("git", "-C", ROOT, *args, binmode: true)
      raise Failure, "git #{args.join(' ')}: #{err.strip}" unless status.success?

      out
    end

    def clean!(*paths)
      dirty = call("status", "--porcelain", "--", *paths)
      raise Failure, "testsuite checkout has uncommitted files:\n#{dirty}" unless dirty.empty?
    end
  end

  class Generator
    def initialize(source, producer_base, umath_commit, jobs: 1, checkpoint: nil, progress: nil)
      @jobs = jobs
      @checkpoint = checkpoint
      @source = source
      @producer_base = producer_base
      @umath_commit = umath_commit
      @progress = progress
      @commit = Git.call("rev-parse", "HEAD").strip
      @fixture_bytes = StageCases.committed_file(ROOT, FIXTURE_PATH)
      @fixture_source, @cases = Fixture.read(@fixture_bytes)
      Fixture.check(@fixture_source, @cases)
    end

    def number
      @source.generation + 1
    end

    def dir
      format("stages/unicode/generations/%06d", number)
    end

    def files
      @files ||= build
    end

    def ledger_entry
      files
      @ledger_entry
    end

    def write(out)
      files.each do |path, bytes|
        target = File.join(out, path)
        FileUtils.mkdir_p(File.dirname(target))
        File.binwrite(target, bytes)
      end
    end

    private

    # { [boundary, fixture id] => expected } for every case and boundary,
    # computed by StageCases::Outcome.agreed in +@jobs+ forked workers. Each
    # worker returns its results through a pipe; any failure stops the run.
    def outcomes
      @outcomes ||= checkpointed { computed_outcomes }
    end

    # With a checkpoint file, outcomes computed by an earlier run of this
    # script for the same umath commit, outcome code and fixture are reused,
    # and fresh ones are saved, so a failure after the long computation does
    # not need it again.
    def checkpointed
      return yield unless @checkpoint

      key = [@umath_commit, Digest::SHA256.file(File.join(StageCases::ROOT, StageCases::GENERATOR_PATH)).hexdigest,
             Digest::SHA256.hexdigest(@fixture_bytes)]
      if File.file?(@checkpoint)
        saved_key, saved = Marshal.load(File.binread(@checkpoint)) # rubocop:disable Security/MarshalLoad
        raise Failure, "#{@checkpoint} was written for #{saved_key.inspect}, not #{key.inspect}" unless saved_key == key

        return saved
      end
      result = yield
      File.binwrite(@checkpoint, Marshal.dump([key, result]))
      result
    end

    def computed_outcomes
      begin
        work = BOUNDARIES.keys.product(@cases)
        shards = work.each_with_index.group_by { |_, i| i % @jobs }.values.map { |s| s.map(&:first) }
        workers = shards.map do |shard|
          reader, writer = IO.pipe
          pid = fork do
            reader.close
            result = begin
              [:ok, shard.to_h do |boundary, c|
                @progress&.call("#{c.id}#{BOUNDARIES.dig(boundary, 'suffix')}")
                [[boundary, c.id], StageCases::Outcome.agreed(c.id, c.input, boundary)]
              end]
            rescue StandardError => e
              [:error, "#{e.class}: #{e.message}"]
            end
            writer.binmode
            writer.write(Marshal.dump(result))
            writer.close
            exit!(0)
          end
          writer.close
          [pid, reader]
        end
        workers.each_with_object({}) do |(pid, reader), all|
          reader.binmode
          data = reader.read
          reader.close
          Process.wait(pid)
          raise Failure, "a worker exited with #{$CHILD_STATUS.exitstatus} and no result" if data.empty?

          status, result = Marshal.load(data) # rubocop:disable Security/MarshalLoad -- our own child
          raise Failure, result if status == :error

          all.merge!(result)
        end
      end
    end

    # A copy with no object reachable twice, so YAML.dump writes no aliases
    # (the validators refuse them).
    def unshared(value)
      JSON.parse(JSON.generate(value, max_nesting: false), max_nesting: false)
    end

    def file_ref(path, bytes)
      { "repository" => TESTSUITE_REPOSITORY, "commit" => @commit, "path" => path,
        "sha256" => Digest::SHA256.hexdigest(bytes) }
    end

    def build
      payloads = {}
      entries = []
      @source.payloads.each do |entry, _doc|
        payloads[entry["path"]] = @source.files.fetch(entry["path"])
        entries << entry.merge("source" => { "relation" => "copy", "file" => @source.file_ref(entry["path"]) })
      end

      producers = @source.provenance.fetch("producers").dup
      BOUNDARIES.each do |boundary, spec|
        raise Failure, "source already has a #{spec['producer']} producer" if producers.key?(spec["producer"])

        producers[spec["producer"]] = producer(boundary)
        @cases.each_slice(GROUP_SIZE) do |slice|
          name = format("%s%03d-%03d", spec["prefix"], slice.first.index, slice.last.index)
          path = "payloads/#{name}.yaml"
          raise Failure, "#{path} already exists in the source generation" if payloads.key?(path)

          bytes = payload(name, boundary, slice)
          payloads[path] = bytes
          entries << { "path" => path, "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes),
                       "producer" => spec["producer"], "source" => { "relation" => "generated", "file" => nil },
                       "rows" => slice.map { |c| "#{c.id}#{spec['suffix']}" } }
        end
      end
      entries.sort_by! { |e| e["path"].b }

      provenance = { "schema" => StageCases::PROVENANCE_SCHEMA, "language" => "unicode", "generation" => number,
                     "notes" => notes, "producers" => producers, "payloads" => entries }
      generation = payloads.dup
      generation["provenance.yaml"] =
        "# Generation #{number} of the unicode stage corpus. Immutable: never edit this\n" \
        "# directory; add a new generation instead. See docs/stage-corpus-contract.adoc.\n" \
        "# Written by #{GENERATOR_PATH} (plurimath/plurimath-testsuite).\n" +
        StageCases.yaml(unshared(provenance))

      @ledger_entry = {
        "generation" => number, "path" => dir, "snapshot_digest" => StageCases.snapshot_digest(generation),
        "payloads" => entries.size, "rows" => entries.sum { |e| e["rows"].size },
        "producer_kinds" => producers.values.map { |p| p["kind"] }.uniq.sort,
        "change" => "extend", "rationale" => rationale
      }
      out = generation.transform_keys { |p| "#{dir}/#{p}" }
      ledger = @source.ledger_bytes.dup.force_encoding(Encoding::UTF_8)
      ledger += "\n" unless ledger.end_with?("\n")
      out["generations/unicode.yaml"] = ledger + StageCases.yaml([@ledger_entry]).delete_prefix("---\n")
      out
    end

    # The frozen stage producer's block (StageCases::Identity) with this
    # script as the generator, the fixture as its input, and the selection
    # recorded in the configuration.
    def producer(boundary)
      base = @producer_base.fetch(boundary)
      config = base.fetch("configuration").reject { |k, _| k == "source_generation" }
      base.merge(
        "generator" => file_ref(GENERATOR_PATH, StageCases.committed_file(ROOT, GENERATOR_PATH)),
        "inputs" => [file_ref(FIXTURE_PATH, @fixture_bytes)],
        "configuration" => config.merge(
          "outcome" => {
            "repository" => StageCases::REPOSITORY, "commit" => @umath_commit,
            "path" => StageCases::GENERATOR_PATH,
            "sha256" => Digest::SHA256.file(File.join(StageCases::ROOT, StageCases::GENERATOR_PATH)).hexdigest,
            "function" => boundary == "typed-model" ? "StageCases::Outcome.model_of" : "StageCases::Outcome.of"
          },
          "selection" => {
            "fixture" => FIXTURE_PATH, "schema" => FIXTURE_SCHEMA, "cases" => @cases.size,
            "ids" => "every fixture case in fixture order; row id = fixture id + #{BOUNDARIES.dig(boundary, 'suffix')}",
            "input" => "the fixture input lexeme without its first character, the upstream display flag " \
                       "(0 inline, 1 block); the fixture's model boundary (remove_prefix)",
            "plain_scalar_inputs" => @cases.select(&:plain).map(&:id),
            "duplicate_inputs" => Fixture.duplicates(@cases),
            "fixture_expectations" => "not compared: the fixture's raw trees are UnicodeMath::Parse after " \
                                      "unicode_encode_entities and its models are Math::Formula (plurimath " \
                                      "#{@fixture_source['revision']}), a different boundary from these rows"
          },
          "upstream" => UPSTREAM,
          "origin" => ORIGIN
        )
      )
    end

    def payload(name, boundary, slice)
      spec = BOUNDARIES.fetch(boundary)
      cases = slice.map do |c|
        { "id" => "#{c.id}#{spec['suffix']}", "input" => StageCases::Canonical.dump(c.input),
          "options" => { "decimal" => DECIMAL },
          "expected" => outcomes.fetch([boundary, c.id]) }
      end
      doc = { "schema" => StageCases::CASES_SCHEMA, "group" => name, "description" => description(boundary, slice),
              "boundary" => boundary, "cases" => cases }
      "# #{boundary == 'typed-model' ? 'Typed-model' : 'Raw-tree'} rows for #{FIXTURE_PATH} cases " \
        "#{slice.first.index}-#{slice.last.index}. Written by\n" \
        "# #{GENERATOR_PATH}. Do not edit; see provenance.yaml.\n" +
        StageCases.yaml(unshared(doc))
    end

    def description(boundary, slice)
      range = "#{slice.first.id} to #{slice.last.id} of #{FIXTURE_PATH}"
      if boundary == "typed-model"
        "Typed model (Umath::Model::Document) from Umath.parse for #{range}, each input without its " \
          "upstream display flag: the preprocessing and the model, each object its model class " \
          "(#{StageCases::LML}) with its set fields in declaration order (nil fields left out), or a refusal " \
          "with its byte offset into the caller's input. Not the fixture's Math::Formula. Default decimal " \
          "marker; the Ruby and native engines agree on every row."
      else
        "Umath::RawParser outcome for #{range}, each input without its upstream display flag: the " \
          "preprocessing and the raw grammar tree, or a refusal with its byte offset into the preprocessed " \
          "text. Not the fixture's UnicodeMath::Parse tree. Default decimal marker; the Ruby and native " \
          "engines agree on every row."
      end
    end

    def notes
      "Generation #{@source.generation} (#{@source.dir} at plurimath-testsuite #{@source.commit}, " \
        "#{@source.entry['snapshot_digest']}) copied byte for byte, plus raw-external-* and model-external-* " \
        "payloads with the umath raw-tree and typed-model outcome of each of the #{@cases.size} cases of " \
        "#{FIXTURE_PATH} (ids kept; row id = fixture id + .raw or .model), computed by scripts/stage_cases.rb " \
        "at umath #{@umath_commit} and written by #{GENERATOR_PATH}. The inputs come from plurimath/unicodemath-tests " \
        "(#{UPSTREAM['commit']}), taken from MurrayIII/UnicodeMathML (MIT, Copyright (c) 2019 Noah Doersing; " \
        "see #{ORIGIN['notice']}). The fixture's expectations and the upstream MathML are references, not " \
        "oracles for these rows."
    end

    def rationale
      "Keeps every generation #{@source.generation} payload byte for byte and adds umath raw-tree and " \
        "typed-model rows (Ruby and native engines agreeing) for all #{@cases.size} external UnicodeMath " \
        "inputs of #{FIXTURE_PATH}, computed by scripts/stage_cases.rb at umath #{@umath_commit} and written " \
        "by #{GENERATOR_PATH}."
    end
  end

  class GeneratorCLI
    def initialize(argv)
      @options = {}
      OptionParser.new do |o|
        o.banner = "usage: scripts/generate-unicode-external.rb --umath DIR --out DIR [--jobs N] [--checkpoint FILE]"
        o.on("--umath DIR") { |v| @options[:umath] = File.expand_path(v) }
        o.on("--out DIR") { |v| @options[:out] = v }
        o.on("--jobs N", Integer) { |v| @options[:jobs] = v }
        o.on("--checkpoint FILE") { |v| @options[:checkpoint] = v }
      end.parse!(argv)
      raise Failure, "--umath and --out are required" unless @options[:umath] && @options[:out]
    end

    def run
      load_producer(@options[:umath])
      Git.clean!(GENERATOR_PATH, FIXTURE_PATH, "stages", "generations")
      source = StageCases::Source.new(ROOT)
      umath_commit = StageCases::Identity.git("rev-parse", "HEAD").strip
      producers = BOUNDARIES.keys.to_h { |b| [b, StageCases::Identity.producer(source, b)] }
      generator = Generator.new(source, producers, umath_commit, jobs: @options.fetch(:jobs, 1), checkpoint: @options[:checkpoint],
                                                  progress: ->(id) { warn "  #{id}" })
      generator.write(@options[:out])
      entry = generator.ledger_entry
      puts "#{generator.dir}: #{entry['payloads']} payloads, #{entry['rows']} rows, #{entry['snapshot_digest']}"
      0
    end

    def load_producer(umath)
      require File.join(umath, "scripts", "stage_cases.rb")
      raise Failure, "stage_cases.rb uses decimal #{StageCases::DECIMAL.inspect}" unless StageCases::DECIMAL == DECIMAL
      return if StageCases::ROOT == umath

      raise Failure, "loaded StageCases from #{StageCases::ROOT}, not #{umath}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit UnicodeExternal::GeneratorCLI.new(ARGV).run
  rescue UnicodeExternal::Failure, OptionParser::ParseError => e
    warn "generate-unicode-external: #{e.message}"
    exit 1
  rescue StandardError => e
    raise unless defined?(StageCases::Failure) && e.is_a?(StageCases::Failure)

    warn "generate-unicode-external: #{e.message}"
    exit 1
  end
end
