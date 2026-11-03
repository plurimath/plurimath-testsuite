#!/usr/bin/env ruby
# frozen_string_literal: true

# Validates the immutable stage generations under stages/ and their ledgers
# under generations/, as docs/stage-corpus-contract.adoc describes.
#
#   ruby scripts/validate-stages.rb [root] [--base REF] [--pin FILE]
#
# The legacy corpus under corpus/ is scripts/validate.rb's business and is not
# read here. This script reuses validate.rb's JSON Schema subset and nothing
# else from it, and like it runs with plain `ruby`: no gems.
#
# What it checks, for every language:
#
# * layout: stages/<language>/generations/<NNNNNN>/provenance.yaml and
#   .../payloads/<group>.yaml only, no symlinks, and generations/<language>.yaml
#   for every stages/<language>, and no other files;
# * each ledger and provenance against its schema; generations numbered 1, 2,
#   ... with no gaps, each one listed in the ledger and present on disk;
# * each provenance lists exactly the payload files on disk, sorted, with the
#   right size, sha256 and case ids, and each payload validates against the
#   schema it declares and belongs to this language;
# * the ledger's snapshot digest is the one recomputed from the files, and
#   every generation has at least one replayable row;
# * generation N keeps every case of generation N-1: same id, same input and
#   same expected outcomes.
#
# With --base REF (a commit, normally the PR base), additionally:
#
# * every ledger at REF is an unchanged prefix of the current ledger;
# * every file under stages/ at REF still exists with identical bytes, and no
#   file was added to a generation directory that REF already had.
#
# With --pin FILE, additionally checks that pin (a consumer's
# spec/fixtures/testsuite-pin.yml): its commit is the checkout's HEAD, the
# named generation exists, and its digest matches the ledger and the files.

require "digest"
require "json"
require "open3"
require "yaml"
require_relative "validate"

module Testsuite
  module Stages
    LAYOUT_REVISION = 1
    LANGUAGES = %w[asciimath latex unicode mathml omml html roundtrip].freeze
    GENERATION_DIR = /\A[0-9]{6}\z/
    GROUP_FILE = /\A[a-z0-9]+(?:-[a-z0-9]+)*\.yaml\z/
    REPOSITORY = "https://github.com/plurimath/plurimath-testsuite"

    # sha256 over `<sha256>  <path>\n` for every file of a generation, paths
    # relative to the generation directory and ordered by their bytes.
    def self.snapshot_digest(files)
      lines = files.sort_by { |path, _| path.b }.map do |path, bytes|
        "#{Digest::SHA256.hexdigest(bytes)}  #{path}\n"
      end
      "sha256:#{Digest::SHA256.hexdigest(lines.join.encode('UTF-8'))}"
    end

    class Runner
      def initialize(root:, schema_dir:, base: nil, pin: nil)
        @root = File.expand_path(root)
        @schema_dir = File.expand_path(schema_dir)
        @base = base
        @pin = pin
        @failures = 0
        @stats = Hash.new(0)
        @ledgers = {}
        @generations = {}
      end

      def run
        @schemas = load_schemas
        files = tree_files
        if files.empty?
          puts "FAIL  no stage files under #{display(@root)}; a validator " \
               "that validates nothing is not a pass"
          return 1
        end

        languages = check_layout(files)
        languages.each { |language| check_language(language, files) }
        check_base(files) if @base
        check_pin if @pin

        puts
        summary
        @failures.zero? ? 0 : 1
      end

      private

      # --- schemas -----------------------------------------------------------

      def load_schemas
        paths = Dir.glob(File.join(@schema_dir, "*.json")).sort
        raise Failure, "no schemas in #{display(@schema_dir)}" if paths.empty?

        paths.map do |path|
          document = begin
            JSON.parse(File.read(path))
          rescue JSON::ParserError => e
            raise Failure, "#{display(path)}: invalid JSON: #{e.message}"
          end
          JsonSchema::Schema.new(document, display(path))
        end
      end

      def schema_errors(document, expected = nil)
        declared = document.is_a?(Hash) ? document["schema"] : nil
        matches = @schemas.select { |s| s.accepts_declaration?(declared) }
        if expected && declared != expected
          return ["/schema: must be #{expected}, got #{declared.inspect}"]
        end
        return ["/schema: #{declared.inspect} matches no schema"] if matches.empty?
        if matches.length > 1
          return ["/schema: #{declared.inspect} matches #{matches.length} schemas"]
        end

        matches.first.validate(document).map(&:to_s)
      end

      # --- files -------------------------------------------------------------

      # Every file under stages/ and generations/, relative to the root.
      def tree_files
        %w[stages generations].flat_map do |top|
          dir = File.join(@root, top)
          next [] unless File.exist?(dir)

          entries = Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH)
            .reject { |e| %w[. ..].include?(File.basename(e)) }
          links = [dir, *entries].select { |e| File.symlink?(e) }
          unless links.empty?
            raise Failure, "stage trees may not contain symlinks: " \
                           "#{links.map { |e| display(e) }.join(', ')}"
          end

          entries.reject { |e| File.directory?(e) }
            .map { |e| e.delete_prefix("#{@root}/") }
        end.sort
      end

      def check_layout(files)
        languages = []
        files.each do |path|
          parts = path.split("/")
          if parts[0] == "generations"
            language = parts[1]&.delete_suffix(".yaml")
            next if parts.length == 2 && parts[1].end_with?(".yaml") &&
              LANGUAGES.include?(language)
          elsif parts[0] == "stages" && LANGUAGES.include?(parts[1]) &&
              parts[2] == "generations" && parts[3]&.match?(GENERATION_DIR)
            next languages << parts[1] if parts.length == 5 &&
              parts[4] == "provenance.yaml"
            next languages << parts[1] if parts.length == 6 &&
              parts[4] == "payloads" &&
              parts[5].match?(GROUP_FILE)
          end
          fail_with(path, "is not a file the stage layout allows; expected " \
                          "generations/<language>.yaml, or " \
                          "stages/<language>/generations/<NNNNNN>/" \
                          "{provenance.yaml,payloads/<group>.yaml}, with " \
                          "<language> one of #{LANGUAGES.join(', ')}")
        end

        ledger_languages = files.filter_map do |path|
          match = path.match(%r{\Agenerations/([a-z]+)\.yaml\z})
          match && LANGUAGES.include?(match[1]) ? match[1] : nil
        end
        (languages | ledger_languages).sort
      end

      # --- one language ------------------------------------------------------

      def check_language(language, files)
        ledger_path = "generations/#{language}.yaml"
        unless files.include?(ledger_path)
          return fail_with(ledger_path,
                           "is missing; stages/#{language} has generations " \
                           "but no ledger")
        end

        ledger = load_yaml(ledger_path) or return
        errors = schema_errors(ledger, "plurimath-stage/ledger/1")
        return fail_with(ledger_path, *errors) unless errors.empty?

        @ledgers[language] = ledger
        if ledger["language"] != language
          errors << "/language: is #{ledger['language']}, but the file is " \
                    "#{ledger_path}"
        end

        on_disk = files.filter_map do |path|
          match = path.match(%r{\Astages/#{language}/generations/([0-9]{6})/})
          match && match[1]
        end.uniq.sort
        listed = ledger["entries"].map { |e| format("%06d", e["generation"]) }
        (on_disk - listed).each do |dir|
          errors << "does not list stages/#{language}/generations/#{dir}, " \
                    "which exists"
        end

        previous = nil
        ledger["entries"].each_with_index do |entry, index|
          pointer = "/entries/#{index}"
          number = entry["generation"]
          if number != index + 1
            errors << "#{pointer}/generation: is #{number}; generations " \
                      "are numbered 1, 2, ... in order with no gaps"
            next
          end

          change = index.zero? ? "initial" : "extend"
          if entry["change"] != change
            errors << "#{pointer}/change: must be #{change} for generation " \
                      "#{number}"
          end
          path = format("stages/%s/generations/%06d", language, number)
          errors << "#{pointer}/path: must be #{path}" if entry["path"] != path

          snapshot = check_generation(language, number, files)
          unless snapshot
            errors << "#{pointer}: generation #{number} is missing or invalid"
            next
          end

          @generations[[language, number]] = snapshot
          compare_entry(entry, snapshot, pointer, errors)
          carry_forward(previous, snapshot, language) if previous
          previous = snapshot
        end

        return fail_with(ledger_path, *errors) unless errors.empty?

        ok(ledger_path, "#{ledger['entries'].length} generation(s)")
      end

      def compare_entry(entry, snapshot, pointer, errors)
        if entry["snapshot_digest"] != snapshot[:digest]
          errors << "#{pointer}/snapshot_digest: records " \
                    "#{entry['snapshot_digest']}, but the files hash to " \
                    "#{snapshot[:digest]}"
        end
        if entry["payloads"] != snapshot[:payloads].length
          errors << "#{pointer}/payloads: records #{entry['payloads']}, but " \
                    "the generation has #{snapshot[:payloads].length}"
        end
        if entry["rows"] != snapshot[:rows]
          errors << "#{pointer}/rows: records #{entry['rows']}, but the " \
                    "generation has #{snapshot[:rows]}"
        end
        return if entry["producer_kinds"].sort == snapshot[:producer_kinds]

        errors << "#{pointer}/producer_kinds: records " \
                  "#{entry['producer_kinds'].inspect}, but the payloads " \
                  "name #{snapshot[:producer_kinds].inspect}"
      end

      # Returns { digest:, payloads:, rows:, producer_kinds:, cases: } or nil.
      def check_generation(language, number, files)
        dir = format("stages/%s/generations/%06d", language, number)
        provenance_path = "#{dir}/provenance.yaml"
        unless files.include?(provenance_path)
          fail_with(provenance_path, "is missing")
          return nil
        end

        provenance = load_yaml(provenance_path) or return nil
        errors = schema_errors(provenance, "plurimath-stage/provenance/1")
        return fail_with(provenance_path, *errors) unless errors.empty?

        if provenance["language"] != language
          errors << "/language: must be #{language}"
        end
        if provenance["generation"] != number
          errors << "/generation: must be #{number}"
        end

        entries = provenance["payloads"]
        names = entries.map { |e| e["path"] }
        if names != names.sort_by(&:b)
          errors << "/payloads: must be sorted by path"
        end
        names.tally.select { |_, n| n > 1 }.each_key do |name|
          errors << "/payloads: lists #{name} more than once"
        end

        payload_dir = "#{dir}/payloads/"
        on_disk = files.select { |f| f.start_with?(payload_dir) }
          .map { |f| f.delete_prefix("#{dir}/") }
        (on_disk - names).each do |name|
          errors << "/payloads: does not list #{dir}/#{name}, which exists"
        end

        snapshot = { payloads: [], rows: 0, cases: {}, producer_kinds: [] }
        entries.each_with_index do |entry, index|
          check_payload(language, dir, entry, "/payloads/#{index}",
                        provenance, snapshot, errors)
        end

        if snapshot[:rows].zero?
          errors << "/payloads: the generation has no replayable rows; an " \
                    "empty replay is not a pass"
        end
        return fail_with(provenance_path, *errors) unless errors.empty?

        contents = (on_disk + ["provenance.yaml"]).map do |name|
          [name, File.binread(File.join(@root, dir, name))]
        end
        snapshot[:digest] = Stages.snapshot_digest(contents)
        snapshot[:producer_kinds] = snapshot[:producer_kinds].uniq.sort
        @stats[:generations] += 1
        @stats[:payloads] += snapshot[:payloads].length
        @stats[:rows] += snapshot[:rows]
        ok(dir, "#{snapshot[:payloads].length} payloads, " \
                "#{snapshot[:rows]} rows, #{snapshot[:digest]}")
        snapshot
      end

      def check_payload(language, dir, entry, pointer, provenance, snapshot,
                        errors)
        name = entry["path"]
        file = File.join(@root, dir, name)
        unless File.file?(file)
          return errors << "#{pointer}/path: lists #{name}, which is not a " \
                           "file in #{dir}"
        end

        bytes = File.binread(file)
        digest = Digest::SHA256.hexdigest(bytes)
        if digest != entry["sha256"]
          errors << "#{pointer}/sha256: records #{entry['sha256']}, but " \
                    "#{name} hashes to #{digest}"
        end
        if bytes.bytesize != entry["bytes"]
          errors << "#{pointer}/bytes: records #{entry['bytes']}, but " \
                    "#{name} is #{bytes.bytesize} bytes"
        end
        source = entry["source"]
        if source["relation"] == "copy"
          if source["file"].nil?
            errors << "#{pointer}/source/file: a copy names the file it copies"
          elsif source["file"]["sha256"] != entry["sha256"]
            errors << "#{pointer}/source: a copy has the sha256 of the file " \
                      "it copies"
          end
        end

        producer = provenance["producers"][entry["producer"]]
        if producer.nil?
          errors << "#{pointer}/producer: names #{entry['producer']}, which " \
                    "/producers does not define"
        else
          snapshot[:producer_kinds] << producer["kind"]
        end

        snapshot[:payloads] << name
        payload = load_yaml("#{dir}/#{name}") or return
        payload_errors = schema_errors(payload)
        payload_errors += payload_language_errors(payload, language, name)
        unless payload_errors.empty?
          return fail_with("#{dir}/#{name}", *payload_errors)
        end

        cases = payload["cases"]
        ids = cases.map { |c| c["id"] }
        if ids != entry["rows"]
          errors << "#{pointer}/rows: must list the payload's case ids in " \
                    "file order"
        end
        cases.each do |c|
          if snapshot[:cases].key?(c["id"])
            errors << "#{pointer}: case id #{c['id']} appears twice in the " \
                      "generation"
          end
          snapshot[:cases][c["id"]] = c
        end
        snapshot[:rows] += cases.length
      end

      def payload_language_errors(payload, language, name)
        errors = []
        segments = payload["schema"].to_s.split("/")
        kind = segments[1]
        if segments.first == "plurimath-stage"
          expected = kind == "roundtrip" ? "roundtrip" : language
          if kind != expected || (kind == "roundtrip") != (language == "roundtrip")
            errors << "/schema: #{payload['schema']} does not belong under " \
                      "stages/#{language}"
          end
        elsif !%w[rejections calls].include?(kind) && kind != language
          errors << "/schema: #{payload['schema']} is a #{kind} payload, " \
                    "not #{language}"
        end
        if payload.key?("input_format") && payload["input_format"] != language
          errors << "/input_format: must be #{language}"
        end
        Array(payload["cases"]).each_with_index do |c, index|
          next unless c.is_a?(Hash) && c.key?("input_format")
          next if c["input_format"] == language

          errors << "/cases/#{index}/input_format: must be #{language}"
        end
        group = name.delete_prefix("payloads/").delete_suffix(".yaml")
        if payload.key?("group") && payload["group"] != group
          errors << "/group: must be #{group}, the file name"
        end
        unless payload["cases"].is_a?(Array) &&
            payload["cases"].all? do |c|
              c.is_a?(Hash) && c["id"].is_a?(String)
            end
          errors << "/cases: must be a list of cases with string ids"
        end
        errors
      end

      # Every case of the previous generation is still here, with the same
      # input and the same expected outcomes. New cases, and new expectation
      # keys on an old case, are allowed.
      def carry_forward(previous, current, language)
        errors = []
        previous[:cases].each do |id, old|
          now = current[:cases][id]
          next errors << "drops case #{id}" if now.nil?

          old.each do |key, value|
            if key == "expected" && value.is_a?(Hash) && now[key].is_a?(Hash)
              value.each do |target, outcome|
                next if now[key][target] == outcome

                errors << "case #{id}: changes expected #{target}"
              end
            elsif key != "description" && now[key] != value
              errors << "case #{id}: changes #{key}"
            end
          end
        end
        return if errors.empty?

        fail_with("stages/#{language}", "a generation must keep every case " \
                                        "of the one before it", *errors)
      end

      # --- --base ------------------------------------------------------------

      def check_base(_files)
        commit = git("rev-parse", "--verify", "#{@base}^{commit}").strip
        format_name = git("rev-parse", "--show-object-format").strip
        hasher = format_name == "sha256" ? Digest::SHA256 : Digest::SHA1
        listing = git("ls-tree", "-r", "-z", commit, "--", "stages",
                      "generations")
        base_files = listing.split("\0").to_h do |line|
          meta, path = line.split("\t", 2)
          [path, meta.split(" ")[2]]
        end

        base_files.each do |path, blob|
          file = File.join(@root, path)
          unless File.file?(file) && !File.symlink?(file)
            next fail_with(path, "existed at base #{commit[0, 12]} and is " \
                                 "gone; generations and ledgers are never " \
                                 "removed")
          end
          next if path.start_with?("generations/")

          bytes = File.binread(file)
          actual = hasher.hexdigest("blob #{bytes.bytesize}\0#{bytes}")
          next if actual == blob

          fail_with(path, "differs from base #{commit[0, 12]}; a committed " \
                          "generation is immutable")
        end

        base_dirs = base_files.keys.filter_map do |path|
          path[%r{\Astages/[a-z]+/generations/[0-9]{6}/}]
        end.uniq
        tree_files.each do |path|
          next unless base_dirs.any? { |dir| path.start_with?(dir) }
          next if base_files.key?(path)

          fail_with(path, "was added to a generation that base " \
                          "#{commit[0, 12]} already has; add a new generation")
        end

        base_files.each_key do |path|
          match = path.match(%r{\Agenerations/([a-z]+)\.yaml\z}) or next
          old = YAML.safe_load(git("show", "#{commit}:#{path}"),
                               aliases: false)
          now = @ledgers[match[1]] or next
          old_entries = Array(old && old["entries"])
          next if now["entries"].first(old_entries.length) == old_entries &&
            now["language"] == old["language"]

          fail_with(path, "is not an append-only extension of the ledger at " \
                          "base #{commit[0, 12]}")
        end
        if @failures.zero?
          puts "  OK    --base #{commit[0, 12]}: earlier generations and " \
               "ledger entries unchanged"
        end
      end

      def git(*args)
        out, err, status = Open3.capture3("git", "-C", @root, *args)
        unless status.success?
          raise Failure,
                "git #{args.join(' ')}: #{err.strip}"
        end

        out
      end

      # --- --pin -------------------------------------------------------------

      def check_pin
        shown = display(File.expand_path(@pin))
        pin = begin
          YAML.safe_load_file(@pin, aliases: false)
        rescue Psych::Exception, Errno::ENOENT => e
          return fail_with(shown, "is not readable YAML: #{e.message}")
        end
        errors = schema_errors(pin, "plurimath-stage/pin/1")
        return fail_with(shown, *errors) unless errors.empty?

        head = git("rev-parse", "HEAD").strip
        if pin["commit"] != head
          errors << "/commit: pins #{pin['commit']}, but the checkout is at " \
                    "#{head}"
        end
        ledger = @ledgers[pin["language"]]
        entry = ledger && ledger["entries"].find do |e|
          e["generation"] == pin["generation"]
        end
        snapshot = @generations[[pin["language"], pin["generation"]]]
        if entry.nil?
          errors << "/generation: #{pin['language']} has no generation " \
                    "#{pin['generation']}"
        elsif entry["snapshot_digest"] != pin["snapshot_digest"]
          errors << "/snapshot_digest: pins #{pin['snapshot_digest']}, but " \
                    "the ledger records #{entry['snapshot_digest']}"
        end
        if entry && (snapshot.nil? || snapshot[:digest] != pin["snapshot_digest"])
          errors << "/snapshot_digest: the generation's files do not hash " \
                    "to the pinned digest"
        end
        return fail_with(shown, *errors) unless errors.empty?

        ok(shown, "#{pin['language']} generation #{pin['generation']}, " \
                  "#{snapshot[:rows]} rows")
      end

      # --- reporting ---------------------------------------------------------

      def load_yaml(relative)
        YAML.safe_load_file(File.join(@root, relative), aliases: false)
      rescue Psych::Exception => e
        fail_with(relative, "is not portable YAML: #{e.class}: #{e.message}")
        nil
      end

      def ok(path, note)
        puts format("  OK    %-52s %s", path, note)
      end

      def fail_with(path, *messages)
        @failures += 1
        puts "  FAIL  #{path}"
        messages.uniq.first(25).each { |m| puts "          #{m}" }
        puts "          ... #{messages.uniq.length - 25} more" if messages.uniq.length > 25
        nil
      end

      def summary
        counts = "#{@ledgers.length} ledgers, #{@stats[:generations]} " \
                 "generations, #{@stats[:payloads]} payloads, " \
                 "#{@stats[:rows]} rows (layout revision #{LAYOUT_REVISION})"
        if @failures.zero?
          puts "#{counts} — all valid"
        else
          puts "#{counts} — #{@failures} failure(s)"
        end
      end

      def display(path)
        relative = path.delete_prefix("#{Dir.pwd}/")
        relative.length < path.length ? relative : path
      end
    end

    module CLI
      USAGE = <<~TEXT
        usage: validate-stages.rb [root] [options]

        Validates the immutable stage generations (stages/) and their ledgers
        (generations/) under root. See docs/stage-corpus-contract.adoc.

          root            repository root to validate (default: this repository)
          --schema DIR    schema directory (default: <this repository>/schema)
          --base REF      also require every generation and ledger entry at REF
                          to be unchanged (needs root to be a git checkout)
          --pin FILE      also verify a consumer's stage pin against root
                          (needs root to be a git checkout at the pinned commit)
          -h, --help      this message

        Exits 0 when everything is valid, 1 on any violation, 2 on a usage,
        schema or git error.
      TEXT

      def self.run(argv)
        repo = File.expand_path("..", __dir__)
        options = { root: repo, schema_dir: File.join(repo, "schema") }
        positional = []
        until argv.empty?
          argument = argv.shift
          case argument
          when "-h", "--help"
            puts USAGE
            return 0
          when "--schema", "--base", "--pin"
            value = argv.shift or raise Failure, "#{argument} needs a value"
            key = { "--schema" => :schema_dir, "--base" => :base,
                    "--pin" => :pin }[argument]
            options[key] = value
          when /\A--(schema|base|pin)=(.+)\z/
            key = { "schema" => :schema_dir }.fetch(Regexp.last_match(1),
                                                    Regexp.last_match(1).to_sym)
            options[key] = Regexp.last_match(2)
          when /\A-/ then raise Failure,
                                "unknown option #{argument}\n\n#{USAGE}"
          else positional << argument
          end
        end
        raise Failure, "expected at most one root" if positional.length > 1

        options[:root] = positional.first if positional.first
        Runner.new(**options).run
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit Testsuite::Stages::CLI.run(ARGV)
  rescue Testsuite::Failure, Errno::ENOENT => e
    warn "validate-stages: #{e.message}"
    exit 2
  end
end
