#!/usr/bin/env ruby
# frozen_string_literal: true

# Validates every corpus file against the schema it declares.
#
#   ruby scripts/validate.rb [corpus-root] [options]
#
# Each payload names its own schema in a top-level `schema:` key, so the file
# picks the schema rather than the directory layout picking it. Every schema in
# schema/ constrains that key with `const` or `pattern`; dispatch is the schema
# whose constraint the declared value satisfies, and exactly one must match.
#
# No gems: the JSON Schema subset the corpus schemas use is implemented here,
# with a keyword whitelist so a schema cannot quietly use a keyword this
# validator ignores. `json_schemer` is the reference implementation these
# schemas are cross-checked against by hand; it is not required to run CI.

require "digest"
require "json"
require "yaml"

module Testsuite
  Error = Struct.new(:path, :message) do
    def to_s
      "#{path.empty? ? '/' : path}: #{message}"
    end
  end

  class Failure < StandardError; end

  # --- JSON Schema, draft 2020-12 (the subset these schemas use) ------------
  module JsonSchema
    DIALECT = "https://json-schema.org/draft/2020-12/schema"

    # Keyword => how to recurse into its value. Anything absent from this table
    # is rejected at load time: a keyword this validator does not implement
    # must fail loudly, never be ignored into a false pass.
    KEYWORDS = {
      "$schema" => :none, "$id" => :none, "$ref" => :none, "$comment" => :none,
      "title" => :none, "description" => :none, "default" => :none,
      "examples" => :none,
      "$defs" => :map, "properties" => :map, "patternProperties" => :map,
      "type" => :none, "enum" => :none, "const" => :none,
      "required" => :none, "minProperties" => :none, "maxProperties" => :none,
      "additionalProperties" => :schema, "propertyNames" => :schema,
      "items" => :schema, "prefixItems" => :list,
      "minItems" => :none, "maxItems" => :none, "uniqueItems" => :none,
      "minLength" => :none, "maxLength" => :none, "pattern" => :none,
      "minimum" => :none, "maximum" => :none, "exclusiveMinimum" => :none,
      "exclusiveMaximum" => :none, "multipleOf" => :none,
      "allOf" => :list, "anyOf" => :list, "oneOf" => :list,
      "not" => :schema, "if" => :schema, "then" => :schema, "else" => :schema,
    }.freeze

    TYPES = %w[null boolean object array number integer string].freeze

    class Schema
      attr_reader :path, :id, :root

      def initialize(root, path)
        @root = root
        @path = path
        @regexps = {}
        lint!
        @id = root["$id"]
      end

      # The value of a payload's `schema:` key that this schema claims.
      def declares
        constraint = @root.dig("properties", "schema") || {}
        constraint["const"] || constraint["pattern"]
      end

      def accepts_declaration?(value)
        return false unless value.is_a?(String)

        constraint = @root.dig("properties", "schema") || {}
        return constraint["const"] == value if constraint.key?("const")
        return !regexp(constraint["pattern"]).match(value).nil? if constraint.key?("pattern")

        false
      end

      def validate(instance)
        errors = []
        check(@root, instance, "", errors)
        errors
      end

      private

      # --- load-time checks on the schema itself ---------------------------

      def lint!
        unless @root.is_a?(Hash)
          raise Failure, "#{@path}: a schema must be a JSON object"
        end
        unless @root["$schema"] == DIALECT
          raise Failure, "#{@path}: $schema must be #{DIALECT}, got #{@root['$schema'].inspect}"
        end
        unless @root["$id"].is_a?(String) && @root["$id"].match?(%r{/\d+\z})
          raise Failure,
                "#{@path}: $id must end in a version segment, e.g. .../cases/1 " \
                "(got #{@root['$id'].inspect})"
        end
        unless declares
          raise Failure,
                "#{@path}: properties.schema must pin the payload kind with " \
                "`const` or `pattern`, so a payload can select its schema"
        end

        lint_subschema(@root, "#")
      end

      def lint_subschema(schema, where)
        return if schema == true || schema == false

        unless schema.is_a?(Hash)
          raise Failure, "#{@path}: #{where} is not a schema (#{schema.class})"
        end

        schema.each_key do |keyword|
          unless KEYWORDS.key?(keyword)
            raise Failure,
                  "#{@path}: #{where} uses `#{keyword}`, which this validator " \
                  "does not implement; implement it or drop it"
          end
        end

        if (pattern = schema["pattern"])
          regexp(pattern) # compiles, or raises here rather than mid-run
        end
        if (ref = schema["$ref"])
          resolve(ref, where)
        end

        schema.each do |keyword, value|
          case KEYWORDS[keyword]
          when :schema then lint_subschema(value, "#{where}/#{keyword}")
          when :map
            unless value.is_a?(Hash)
              raise Failure, "#{@path}: #{where}/#{keyword} must be an object"
            end

            value.each { |k, v| lint_subschema(v, "#{where}/#{keyword}/#{k}") }
          when :list
            unless value.is_a?(Array)
              raise Failure, "#{@path}: #{where}/#{keyword} must be an array"
            end

            value.each_with_index { |v, i| lint_subschema(v, "#{where}/#{keyword}/#{i}") }
          end
        end
      end

      def resolve(ref, where = "#")
        unless ref.start_with?("#/")
          raise Failure,
                "#{@path}: #{where} uses the external reference #{ref.inspect}; " \
                "only local #/... references are supported"
        end

        node = @root
        ref.delete_prefix("#/").split("/").each do |token|
          token = token.gsub("~1", "/").gsub("~0", "~")
          unless node.is_a?(Hash) && node.key?(token)
            raise Failure, "#{@path}: #{where} references #{ref}, which does not exist"
          end

          node = node[token]
        end
        node
      end

      # JSON Schema patterns are ECMA-262: `^` and `$` anchor the whole string,
      # while Ruby's anchor to a line. Translate them, so a newline cannot slip
      # a value past an anchored pattern.
      def regexp(pattern)
        @regexps[pattern] ||= begin
          source = +""
          in_class = false
          escaped = false
          pattern.each_char do |char|
            if escaped
              source << char
              escaped = false
              next
            end

            case char
            when "\\" then source << char; escaped = true
            when "[" then in_class = true; source << char
            when "]" then in_class = false; source << char
            when "^" then source << (in_class ? char : '\A')
            when "$" then source << (in_class ? char : '\z')
            else source << char
            end
          end
          begin
            Regexp.new(source)
          rescue RegexpError => e
            raise Failure, "#{@path}: pattern #{pattern.inspect} does not compile: #{e.message}"
          end
        end
      end

      # --- instance validation ---------------------------------------------

      def check(schema, instance, path, errors)
        return if schema == true
        if schema == false
          errors << Error.new(path, "no value is allowed here")
          return
        end

        check(resolve(schema["$ref"]), instance, path, errors) if schema["$ref"]

        check_type(schema, instance, path, errors)
        check_enum(schema, instance, path, errors)
        check_string(schema, instance, path, errors) if instance.is_a?(String)
        check_number(schema, instance, path, errors) if number?(instance)
        check_array(schema, instance, path, errors) if instance.is_a?(Array)
        check_object(schema, instance, path, errors) if instance.is_a?(Hash)
        check_logic(schema, instance, path, errors)
      end

      def number?(value)
        value.is_a?(Numeric) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
      end

      def type_name(value)
        case value
        when nil then "null"
        when true, false then "boolean"
        when Integer then "integer"
        when Float then "number"
        when String then "string"
        when Array then "array"
        when Hash then "object"
        else value.class.to_s
        end
      end

      def matches_type?(type, value)
        case type
        when "null" then value.nil?
        when "boolean" then value == true || value == false
        when "object" then value.is_a?(Hash)
        when "array" then value.is_a?(Array)
        when "string" then value.is_a?(String)
        when "integer"
          value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value == value.truncate)
        when "number" then number?(value)
        else raise Failure, "#{@path}: unknown type #{type.inspect}"
        end
      end

      def check_type(schema, instance, path, errors)
        return unless (type = schema["type"])

        wanted = Array(type)
        wanted.each { |t| raise Failure, "#{@path}: unknown type #{t.inspect}" unless TYPES.include?(t) }
        return if wanted.any? { |t| matches_type?(t, instance) }

        errors << Error.new(path, "expected #{wanted.join(' or ')}, got #{type_name(instance)}")
      end

      def check_enum(schema, instance, path, errors)
        if schema.key?("enum") && !schema["enum"].include?(instance)
          errors << Error.new(path,
                              "#{instance.inspect} is not one of " \
                              "#{schema['enum'].map(&:inspect).join(', ')}")
        end
        return unless schema.key?("const") && schema["const"] != instance

        errors << Error.new(path, "expected #{schema['const'].inspect}, got #{instance.inspect}")
      end

      def check_string(schema, instance, path, errors)
        if (min = schema["minLength"]) && instance.length < min
          errors << Error.new(path, "is shorter than #{min} character#{'s' unless min == 1}")
        end
        if (max = schema["maxLength"]) && instance.length > max
          errors << Error.new(path, "is longer than #{max} character#{'s' unless max == 1}")
        end
        return unless (pattern = schema["pattern"]) && !regexp(pattern).match(instance)

        errors << Error.new(path, "#{truncate(instance)} does not match #{pattern}")
      end

      def check_number(schema, instance, path, errors)
        if (min = schema["minimum"]) && instance < min
          errors << Error.new(path, "#{instance} is less than #{min}")
        end
        if (max = schema["maximum"]) && instance > max
          errors << Error.new(path, "#{instance} is greater than #{max}")
        end
        if (min = schema["exclusiveMinimum"]) && instance <= min
          errors << Error.new(path, "#{instance} is not greater than #{min}")
        end
        if (max = schema["exclusiveMaximum"]) && instance >= max
          errors << Error.new(path, "#{instance} is not less than #{max}")
        end
        return unless (step = schema["multipleOf"]) && (instance % step) != 0

        errors << Error.new(path, "#{instance} is not a multiple of #{step}")
      end

      def check_array(schema, instance, path, errors)
        if (min = schema["minItems"]) && instance.length < min
          errors << Error.new(path, "has #{instance.length} item(s), needs at least #{min}")
        end
        if (max = schema["maxItems"]) && instance.length > max
          errors << Error.new(path, "has #{instance.length} item(s), allows at most #{max}")
        end
        if schema["uniqueItems"] && instance.length != instance.uniq.length
          duplicates = instance.tally.select { |_, n| n > 1 }.keys
          errors << Error.new(path, "has duplicate item(s): #{duplicates.map(&:inspect).join(', ')}")
        end

        (schema["prefixItems"] || []).each_with_index do |sub, index|
          break if index >= instance.length

          check(sub, instance[index], "#{path}/#{index}", errors)
        end

        return unless (items = schema["items"])

        offset = (schema["prefixItems"] || []).length
        instance.each_with_index do |value, index|
          next if index < offset

          check(items, value, "#{path}/#{index}", errors)
        end
      end

      def check_object(schema, instance, path, errors)
        instance.each_key do |key|
          next if key.is_a?(String)

          errors << Error.new(path, "has the non-string key #{key.inspect}")
        end

        if (min = schema["minProperties"]) && instance.size < min
          errors << Error.new(path, "has #{instance.size} propertie(s), needs at least #{min}")
        end
        if (max = schema["maxProperties"]) && instance.size > max
          errors << Error.new(path, "has #{instance.size} propertie(s), allows at most #{max}")
        end

        (schema["required"] || []).each do |key|
          next if instance.key?(key)

          errors << Error.new(path, "is missing the required property `#{key}`")
        end

        properties = schema["properties"] || {}
        patterns = schema["patternProperties"] || {}

        instance.each do |key, value|
          next unless key.is_a?(String)

          pointer = "#{path}/#{escape(key)}"
          matched = false

          if properties.key?(key)
            matched = true
            check(properties[key], value, pointer, errors)
          end
          patterns.each do |pattern, sub|
            next unless regexp(pattern).match(key)

            matched = true
            check(sub, value, pointer, errors)
          end

          if (names = schema["propertyNames"])
            name_errors = []
            check(names, key, pointer, name_errors)
            unless name_errors.empty?
              errors << Error.new(pointer, "is not an allowed property name (#{name_errors.first.message})")
            end
          end

          next if matched || !schema.key?("additionalProperties")

          extra = schema["additionalProperties"]
          if extra == false
            errors << Error.new(pointer, "is not an allowed property")
          else
            check(extra, value, pointer, errors)
          end
        end
      end

      def check_logic(schema, instance, path, errors)
        (schema["allOf"] || []).each { |sub| check(sub, instance, path, errors) }

        if (branches = schema["anyOf"])
          attempts = attempt(branches, instance, path)
          report_branches(attempts, path, errors, "anyOf") unless attempts.any?(&:empty?)
        end

        if (branches = schema["oneOf"])
          attempts = attempt(branches, instance, path)
          valid = attempts.count(&:empty?)
          if valid.zero?
            report_branches(attempts, path, errors, "oneOf")
          elsif valid > 1
            errors << Error.new(path, "matches #{valid} of the oneOf alternatives, expected exactly 1")
          end
        end

        if (sub = schema["not"]) && valid?(sub, instance)
          errors << Error.new(path, "matches a form that is not allowed here#{describe(sub)}")
        end

        return unless schema.key?("if")

        branch = valid?(schema["if"], instance) ? "then" : "else"
        check(schema[branch], instance, path, errors) if schema.key?(branch)
      end

      def attempt(branches, instance, path)
        branches.map do |sub|
          collected = []
          check(sub, instance, path, collected)
          collected
        end
      end

      # Report the closest alternative rather than a bare "nothing matched":
      # the branch with the fewest complaints is almost always the intended one.
      def report_branches(attempts, path, errors, keyword)
        best = attempts.min_by(&:length) || []
        errors << Error.new(path,
                            "matches none of the #{attempts.length} #{keyword} " \
                            "alternatives; the closest one reports:")
        errors.concat(best)
      end

      def valid?(schema, instance)
        collected = []
        check(schema, instance, "", collected)
        collected.empty?
      end

      def describe(schema)
        return "" unless schema.is_a?(Hash)

        required = schema["required"] ||
                   schema["anyOf"]&.filter_map { |s| s["required"] if s.is_a?(Hash) }&.flatten
        return "" unless required&.any?

        " (has #{required.map { |r| "`#{r}`" }.join(', ')})"
      end

      def escape(key)
        key.gsub("~", "~0").gsub("/", "~1")
      end

      def truncate(value)
        text = value.inspect
        text.length > 60 ? "#{text[0, 57]}..." : text
      end
    end
  end

  # --- corpus ---------------------------------------------------------------

  class Report
    attr_reader :files, :payloads, :provenance, :cases, :failures

    def initialize
      @files = 0
      @payloads = 0
      @provenance = 0
      @cases = 0
      @failures = 0
    end

    def seen!
      @files += 1
    end

    def count(kind)
      if kind == :provenance
        @provenance += 1
      else
        @payloads += 1
      end
    end

    def add_cases(number)
      @cases += number
    end

    def fail!
      @failures += 1
    end
  end

  class Runner
    # One provenance document describes the whole corpus, and sits at its root.
    PROVENANCE_PATH = "provenance.yaml"
    PROVENANCE_KIND = "provenance"

    def initialize(corpus_root:, schema_dir:, integrity:, allow_empty:)
      @corpus_root = File.expand_path(corpus_root)
      @schema_dir = File.expand_path(schema_dir)
      @integrity = integrity
      @allow_empty = allow_empty
      @report = Report.new
      @corpus_paths = []
      @provenance_paths = []
      @provenance = {}
    end

    def run
      schemas = load_schemas
      puts "schemas  #{display(@schema_dir)}: " \
           "#{schemas.map { |schema| schema.id.split('/').last(2).join('/') }.join(', ')}"
      puts

      files = corpus_files
      if files.empty?
        return empty_result
      end

      @corpus_paths = files
      files.each { |file| validate_file(file, schemas) }
      check_integrity if @integrity

      puts
      summary
      @report.failures.zero? ? 0 : 1
    end

    private

    def load_schemas
      paths = Dir.glob(File.join(@schema_dir, "*.json")).sort
      if paths.empty?
        raise Failure, "no schemas in #{display(@schema_dir)}"
      end

      schemas = paths.map do |path|
        document = begin
          JSON.parse(File.read(path))
        rescue JSON::ParserError => e
          raise Failure, "#{display(path)}: invalid JSON: #{e.message}"
        end
        JsonSchema::Schema.new(document, display(path))
      end

      declared = schemas.map(&:declares)
      duplicates = declared.tally.select { |_, n| n > 1 }.keys
      unless duplicates.empty?
        raise Failure, "two schemas claim #{duplicates.join(', ')}; dispatch would be ambiguous"
      end

      schemas
    end

    def corpus_files
      unless File.directory?(@corpus_root)
        return [] if @allow_empty

        raise Failure, "no corpus directory at #{display(@corpus_root)}"
      end

      Dir.glob(File.join(@corpus_root, "**", "*.{yaml,yml}")).sort
    end

    def empty_result
      message = "no corpus files under #{display(@corpus_root)}"
      unless @allow_empty
        puts "FAIL  #{message}"
        puts
        puts "0 files validated. A validator that validates nothing is not a pass; " \
             "pass --allow-empty if that is genuinely expected."
        return 1
      end

      puts "note  #{message} (--allow-empty); schemas checked, no payloads validated"
      0
    end

    def validate_file(path, schemas)
      shown = display(path)
      @report.seen!
      document = load_yaml(path)
      return unless document

      unless document.is_a?(Hash)
        return failure(shown, [Error.new("", "a payload must be a mapping, got #{document.class}")])
      end

      declared = document["schema"]
      unless declared.is_a?(String)
        return failure(shown, [Error.new("/schema", "missing; every payload declares the schema it follows")])
      end

      matched = schemas.select { |schema| schema.accepts_declaration?(declared) }
      if matched.empty?
        return failure(shown, [Error.new("/schema", "no schema in #{display(@schema_dir)} claims #{declared.inspect}")])
      end
      if matched.length > 1
        return failure(shown, [Error.new("/schema", "#{declared.inspect} is claimed by #{matched.length} schemas")])
      end

      schema = matched.first
      kind = declared.split("/")[1]
      errors = begin
        schema.validate(document)
      rescue SystemStackError
        [Error.new("", "nests too deeply to validate")]
      end

      if kind == PROVENANCE_KIND
        @report.count(:provenance)
        # Recorded even when it failed: it is still not a payload, so the
        # coverage check must not demand an entry for it.
        @provenance_paths << path
        @provenance[path] = document if errors.empty?
      else
        @report.count(:payload)
        @report.add_cases(document["cases"].length) if document["cases"].is_a?(Array)
      end

      if errors.empty?
        puts "  OK    #{shown.ljust(52)} #{kind}, #{count_of(document)}"
      else
        failure(shown, errors)
      end
    end

    def count_of(document)
      cases = document["cases"]
      return "#{cases.length} case#{'s' unless cases.length == 1}" if cases.is_a?(Array)

      payloads = document["payloads"]
      return "#{payloads.length} payload#{'s' unless payloads.length == 1}" if payloads.is_a?(Array)

      "ok"
    end

    # `aliases: false` is a check, not a precaution: an anchor would make the
    # payload unreadable to a parser that does not resolve them.
    def load_yaml(path)
      YAML.safe_load_file(path, aliases: false)
    rescue Psych::Exception => e
      failure(display(path), [Error.new("", "is not portable YAML: #{e.class}: #{e.message}")])
      nil
    rescue SystemStackError
      failure(display(path), [Error.new("", "nests too deeply to read")])
      nil
    end

    # Provenance is only worth recording if it still describes the corpus it
    # ships with: a payload edited, added, or removed after generation must not
    # validate. `payloads` and the files on disk must be the same set, entry for
    # entry, digest for digest.
    def check_integrity
      expected = File.join(@corpus_root, PROVENANCE_PATH)

      if @provenance_paths.empty?
        return failure(display(expected),
                       [Error.new("", "is missing; without it every payload here is " \
                                      "unattributed and unreproducible")])
      end
      if @provenance_paths.length > 1
        listed = @provenance_paths.map { |path| display(path) }.join(", ")
        return failure(display(expected),
                       [Error.new("", "the corpus has one provenance document, but " \
                                      "#{@provenance_paths.length} declare it: #{listed}")])
      end

      path = @provenance_paths.first
      document = @provenance[path]
      return if document.nil? # it failed its schema; there is nothing to trust

      shown = display(path)
      errors = []
      unless File.expand_path(path) == File.expand_path(expected)
        errors << Error.new("", "must be the corpus root's #{display(expected)}, " \
                                "since `payloads` paths are relative to it")
      end

      unrecorded = check_payloads(document, errors)
      failure(shown, errors) unless errors.empty?
      unrecorded.each do |file|
        failure(display(file),
                [Error.new("", "is not recorded in #{shown}; every payload has a " \
                               "`payloads` entry")])
      end
    end

    # Fills `errors` with what the provenance gets wrong, and returns the payload
    # files it never mentions.
    def check_payloads(document, errors)
      on_disk = payload_files
      recorded = {}

      document["payloads"].each_with_index do |entry, index|
        pointer = "/payloads/#{index}"
        name = entry["path"]
        if recorded.key?(name)
          next errors << Error.new("#{pointer}/path", "records #{name} a second time")
        end

        recorded[name] = true
        file = File.expand_path(File.join(@corpus_root, name))
        unless on_disk.include?(file)
          next errors << Error.new("#{pointer}/path",
                                   "records #{name}, which is not a payload in " \
                                   "#{display(@corpus_root)}")
        end

        check_digest(entry, pointer, file, name, errors)
      end

      on_disk.reject { |file| recorded.key?(relative_to_corpus(file)) }
    end

    def check_digest(entry, pointer, file, name, errors)
      bytes = File.binread(file)
      digest = Digest::SHA256.hexdigest(bytes)
      if digest != entry["sha256"]
        errors << Error.new("#{pointer}/sha256",
                            "records #{entry['sha256']} for #{name}, " \
                            "but that file hashes to #{digest}")
      end
      return if bytes.bytesize == entry["bytes"]

      errors << Error.new("#{pointer}/bytes",
                          "records #{entry['bytes']} bytes for #{name}, " \
                          "but that file is #{bytes.bytesize} bytes")
    end

    # Every corpus file except the provenance itself, which describes them but
    # is not one of them.
    def payload_files
      @payload_files ||= (@corpus_paths - @provenance_paths)
        .map { |path| File.expand_path(path) }
    end

    def relative_to_corpus(path)
      path.delete_prefix("#{@corpus_root}/")
    end

    def failure(shown, errors)
      @report.fail!
      puts "  FAIL  #{shown}"
      errors.first(25).each { |error| puts "          #{error}" }
      puts "          ... #{errors.length - 25} more" if errors.length > 25
      nil
    end

    def summary
      counts = "#{@report.files} file#{'s' unless @report.files == 1}: " \
               "#{@report.payloads} payload#{'s' unless @report.payloads == 1} " \
               "(#{@report.cases} case#{'s' unless @report.cases == 1}), " \
               "#{@report.provenance} provenance"
      if @report.failures.zero?
        puts "#{counts} — all valid"
      else
        puts "#{counts} — #{@report.failures} file#{'s' unless @report.failures == 1} failed"
      end
    end

    def display(path)
      relative = path.delete_prefix("#{Dir.pwd}/")
      relative.length < path.length ? relative : path
    end
  end

  module CLI
    USAGE = <<~TEXT
      usage: validate.rb [corpus-root] [options]

      Validates every YAML file under corpus-root against the schema it declares.

        corpus-root        directory to validate (default: corpus)
        --schema DIR       schema directory (default: schema)
        --no-integrity     skip the provenance checksum and coverage checks
        --allow-empty      succeed when there are no corpus files yet
        -h, --help         this message

      Exits 0 when every file is valid, 1 on any violation, 2 on a usage or
      schema error.
    TEXT

    def self.run(argv)
      root = File.expand_path("..", __dir__)
      options = {
        corpus_root: File.join(root, "corpus"),
        schema_dir: File.join(root, "schema"),
        integrity: true,
        allow_empty: false,
      }
      positional = []

      until argv.empty?
        argument = argv.shift
        case argument
        when "-h", "--help"
          puts USAGE
          return 0
        when "--no-integrity" then options[:integrity] = false
        when "--allow-empty" then options[:allow_empty] = true
        when "--schema"
          options[:schema_dir] = argv.shift or raise Failure, "--schema needs a directory"
        when /\A--schema=(.*)\z/ then options[:schema_dir] = Regexp.last_match(1)
        when /\A-/ then raise Failure, "unknown option #{argument}\n\n#{USAGE}"
        else positional << argument
        end
      end

      raise Failure, "expected at most one corpus root, got #{positional.length}" if positional.length > 1

      options[:corpus_root] = positional.first if positional.first

      Runner.new(**options).run
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit Testsuite::CLI.run(ARGV)
  rescue Testsuite::Failure => e
    warn "validate: #{e.message}"
    exit 2
  rescue Errno::ENOENT => e
    warn "validate: #{e.message}"
    exit 2
  end
end
