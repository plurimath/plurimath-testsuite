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

    # The two values a boolean schema (or a "boolean"-typed instance) may
    # take. Frozen once so the membership test allocates nothing per call.
    BOOLEANS = [true, false].freeze

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
      "not" => :schema, "if" => :schema, "then" => :schema, "else" => :schema
    }.freeze

    TYPES = %w[null boolean object array number integer string].freeze

    # The JSON type name of a value, for error messages. Shared, so a schema
    # violation and a malformed payload name the same thing the same way.
    def self.type_name(value)
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

    # A value inspected for an error message, cut short so one oversized value
    # cannot flood the report.
    def self.truncate(value)
      text = value.inspect
      text.length > 60 ? "#{text[0, 57]}..." : text
    end

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
        if constraint.key?("pattern")
          return !regexp(constraint["pattern"]).match(value).nil?
        end

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
          raise Failure,
                "#{@path}: $schema must be #{DIALECT}, " \
                "got #{@root['$schema'].inspect}"
        end
        unless @root["$id"].is_a?(String) && @root["$id"].match?(%r{/\d+\z})
          raise Failure,
                "#{@path}: $id must end in a version segment, " \
                "e.g. .../cases/1 (got #{@root['$id'].inspect})"
        end
        unless declares
          raise Failure,
                "#{@path}: properties.schema must pin the payload kind with " \
                "`const` or `pattern`, so a payload can select its schema"
        end

        lint_subschema(@root, "#")
      end

      def lint_subschema(schema, where)
        return if BOOLEANS.include?(schema)

        unless schema.is_a?(Hash)
          raise Failure, "#{@path}: #{where} is not a schema (#{schema.class})"
        end

        schema.each_key do |keyword|
          unless KEYWORDS.key?(keyword)
            raise Failure,
                  "#{@path}: #{where} uses `#{keyword}`, which this " \
                  "validator does not implement; implement it or drop it"
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

            value.each_with_index do |v, i|
              lint_subschema(v, "#{where}/#{keyword}/#{i}")
            end
          end
        end
      end

      def resolve(ref, where = "#")
        unless ref.start_with?("#/")
          raise Failure,
                "#{@path}: #{where} uses the external reference " \
                "#{ref.inspect}; only local #/... references are supported"
        end

        node = @root
        ref.delete_prefix("#/").split("/").each do |token|
          token = token.gsub("~1", "/").gsub("~0", "~")
          unless node.is_a?(Hash) && node.key?(token)
            raise Failure,
                  "#{@path}: #{where} references #{ref}, which does not exist"
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
            when "\\"
              source << char
              escaped = true
            when "["
              in_class = true
              source << char
            when "]"
              in_class = false
              source << char
            when "^" then source << (in_class ? char : '\A')
            when "$" then source << (in_class ? char : '\z')
            else source << char
            end
          end
          begin
            Regexp.new(source)
          rescue RegexpError => e
            raise Failure,
                  "#{@path}: pattern #{pattern.inspect} does not compile: " \
                  "#{e.message}"
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
        value.is_a?(Numeric) &&
          !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
      end

      def matches_type?(type, value)
        case type
        when "null" then value.nil?
        when "boolean" then BOOLEANS.include?(value)
        when "object" then value.is_a?(Hash)
        when "array" then value.is_a?(Array)
        when "string" then value.is_a?(String)
        when "integer"
          value.is_a?(Integer) ||
            (value.is_a?(Float) && value.finite? && value == value.truncate)
        when "number" then number?(value)
        else raise Failure, "#{@path}: unknown type #{type.inspect}"
        end
      end

      def check_type(schema, instance, path, errors)
        return unless (type = schema["type"])

        wanted = Array(type)
        wanted.each do |t|
          next if TYPES.include?(t)

          raise Failure, "#{@path}: unknown type #{t.inspect}"
        end
        return if wanted.any? { |t| matches_type?(t, instance) }

        errors << Error.new(path,
                            "expected #{wanted.join(' or ')}, " \
                            "got #{JsonSchema.type_name(instance)}")
      end

      def check_enum(schema, instance, path, errors)
        if schema.key?("enum") && !schema["enum"].include?(instance)
          errors << Error.new(path,
                              "#{instance.inspect} is not one of " \
                              "#{schema['enum'].map(&:inspect).join(', ')}")
        end
        return unless schema.key?("const") && schema["const"] != instance

        errors << Error.new(path,
                            "expected #{schema['const'].inspect}, " \
                            "got #{instance.inspect}")
      end

      def check_string(schema, instance, path, errors)
        if (min = schema["minLength"]) && instance.length < min
          errors << Error.new(path,
                              "is shorter than #{min} " \
                              "character#{'s' unless min == 1}")
        end
        if (max = schema["maxLength"]) && instance.length > max
          errors << Error.new(path,
                              "is longer than #{max} " \
                              "character#{'s' unless max == 1}")
        end
        pattern = schema["pattern"]
        return unless pattern && !regexp(pattern).match(instance)

        errors << Error.new(path,
                            "#{JsonSchema.truncate(instance)} " \
                            "does not match #{pattern}")
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
          errors << Error.new(path,
                              "has #{instance.length} item(s), " \
                              "needs at least #{min}")
        end
        if (max = schema["maxItems"]) && instance.length > max
          errors << Error.new(path,
                              "has #{instance.length} item(s), " \
                              "allows at most #{max}")
        end
        if schema["uniqueItems"] && instance.length != instance.uniq.length
          duplicates = instance.tally.select { |_, n| n > 1 }.keys
          errors << Error.new(path,
                              "has duplicate item(s): " \
                              "#{duplicates.map(&:inspect).join(', ')}")
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
          errors << Error.new(path,
                              "has #{properties(instance.size)}, " \
                              "needs at least #{min}")
        end
        if (max = schema["maxProperties"]) && instance.size > max
          errors << Error.new(path,
                              "has #{properties(instance.size)}, " \
                              "allows at most #{max}")
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
              errors << Error.new(pointer,
                                  "is not an allowed property name " \
                                  "(#{name_errors.first.message})")
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
        (schema["allOf"] || []).each do |sub|
          check(sub, instance, path, errors)
        end

        if (branches = schema["anyOf"])
          attempts = attempt(branches, instance, path)
          unless attempts.any?(&:empty?)
            report_branches(attempts, path, errors, "anyOf")
          end
        end

        if (branches = schema["oneOf"])
          attempts = attempt(branches, instance, path)
          valid = attempts.count(&:empty?)
          if valid.zero?
            report_branches(attempts, path, errors, "oneOf")
          elsif valid > 1
            errors << Error.new(path,
                                "matches #{valid} of the oneOf alternatives, " \
                                "expected exactly 1")
          end
        end

        if (sub = schema["not"]) && valid?(sub, instance)
          errors << Error.new(path,
                              "matches a form that is not " \
                              "allowed here#{describe(sub)}")
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
                            "matches none of the #{attempts.length} " \
                            "#{keyword} alternatives; the closest one reports:")
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
          schema["anyOf"]&.filter_map do |s|
            s["required"] if s.is_a?(Hash)
          end&.flatten
        return "" unless required&.any?

        " (has #{required.map { |r| "`#{r}`" }.join(', ')})"
      end

      def escape(key)
        key.gsub("~", "~0").gsub("/", "~1")
      end

      def properties(count)
        "#{count} #{count == 1 ? 'property' : 'properties'}"
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

    # The corpus holds exactly two kinds of file: the provenance document at
    # its root, and payload groups at `<input-format>/<group>.yaml`. This is
    # an allowlist rather than a wider glob on purpose — a wider glob still
    # ignores the next stray artifact, an allowlist rejects it.
    PAYLOAD_LAYOUT =
      %r{\A[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*\.yaml\z}

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
      names = schemas.map { |schema| schema.id.split("/").last(2).join("/") }
      puts "schemas  #{display(@schema_dir)}: #{names.join(', ')}"
      puts

      files, strays = corpus_files.partition { |path| allowed_layout?(path) }
      if files.empty? && strays.empty?
        return empty_result
      end

      strays.each { |path| reject_stray(path) }
      @corpus_paths = files
      files.each { |file| validate_file(file, schemas) }
      check_integrity if @integrity
      check_readme

      puts
      summary
      @report.failures.zero? ? 0 : 1
    end

    private

    def load_schemas
      paths = Dir.glob(File.join(@schema_dir, "*.json"))
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
        raise Failure,
              "two schemas claim #{duplicates.join(', ')}; " \
              "dispatch would be ambiguous"
      end

      schemas
    end

    # Every file under the corpus root, not just what looks like a payload:
    # a file this validator would not validate must fail the run, never sit
    # invisibly beside it. `allowed_layout?` decides what may exist.
    def corpus_files
      unless File.directory?(@corpus_root)
        return [] if @allow_empty

        raise Failure, "no corpus directory at #{display(@corpus_root)}"
      end

      entries = Dir.glob(File.join(@corpus_root, "**", "*"),
                         File::FNM_DOTMATCH).sort

      # Symlinks are rejected before the directory filter, because that filter
      # FOLLOWS links: a directory symlink would vanish from the listing
      # entirely, and a file symlink with an allowed name would be validated
      # through whatever external target it points at. Both were demonstrated
      # passing. `lstat` is the whole point — it looks at the link itself.
      links = entries.select { |entry| File.symlink?(entry) }
      unless links.empty?
        listed = links.map { |entry| display(entry) }.join(", ")
        raise Failure, "the corpus may not contain symlinks: #{listed}"
      end

      entries.reject { |entry| File.directory?(entry) }
    end

    def allowed_layout?(path)
      relative = relative_to_corpus(File.expand_path(path))
      relative == PROVENANCE_PATH || relative.match?(PAYLOAD_LAYOUT)
    end

    def reject_stray(path)
      @report.seen!
      message = "is not a file the corpus layout allows; expected " \
                "#{PROVENANCE_PATH} at the root, or a payload at " \
                "<input-format>/<group>.yaml (lowercase, `.yaml`)"
      failure(display(path), [Error.new("", message)])
    end

    def empty_result
      message = "no corpus files under #{display(@corpus_root)}"
      unless @allow_empty
        puts "FAIL  #{message}"
        puts
        puts "0 files validated. A validator that validates nothing is not " \
             "a pass; pass --allow-empty if that is genuinely expected."
        return 1
      end

      puts "note  #{message} (--allow-empty); " \
           "schemas checked, no payloads validated"
      0
    end

    def validate_file(path, schemas)
      shown = display(path)
      @report.seen!
      document = load_yaml(path)
      return unless document

      unless document.is_a?(Hash)
        return failure(shown, [Error.new("", "a payload must be a mapping, " \
                                             "got #{document.class}")])
      end

      nonfinite = begin
        nonfinite_errors(document, "")
      rescue SystemStackError
        [Error.new("", "nests too deeply to validate")]
      end
      return failure(shown, nonfinite) unless nonfinite.empty?

      declared = document["schema"]
      unless declared.is_a?(String)
        # An absent key and a key holding the wrong kind of value are different
        # mistakes, and dispatch cannot proceed on either: say which happened.
        reason = if document.key?("schema")
                   "must name a schema as a string, " \
                     "got #{describe_value(declared)}"
                 else
                   "missing; every payload declares the schema it follows"
                 end
        return failure(shown, [Error.new("/schema", reason)])
      end

      matched = schemas.select do |schema|
        schema.accepts_declaration?(declared)
      end
      if matched.empty?
        message = "no schema in #{display(@schema_dir)} " \
                  "claims #{declared.inspect}"
        return failure(shown, [Error.new("/schema", message)])
      end
      if matched.length > 1
        message = "#{declared.inspect} is claimed by #{matched.length} schemas"
        return failure(shown, [Error.new("/schema", message)])
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
        cases = document["cases"]
        @report.add_cases(cases.length) if cases.is_a?(Array)
      end

      # Only once the shape is known good: these checks read fields the schema
      # has just guaranteed are there and are the right type.
      if errors.empty?
        errors = cross_field_errors(document,
                                    relative_to_corpus(File.expand_path(path)))
      end

      if errors.empty?
        puts "  OK    #{shown.ljust(52)} #{kind}, #{count_of(document)}"
      else
        failure(shown, errors)
      end
    end

    # A type name, plus the value itself when the name alone does not say what
    # arrived. A payload can put anything here, so the value is bounded.
    def describe_value(value)
      name = JsonSchema.type_name(value)
      value.nil? ? name : "#{name} #{JsonSchema.truncate(value)}"
    end

    # JSON Schema constrains one field at a time, so a constraint relating two
    # fields — or a field and the file it sits in — has to live here. The
    # schemas describe these constraints; this is what makes the descriptions
    # true. `relative` is the file's path below the corpus root.
    def cross_field_errors(document, relative)
      if listed_payloads?(document)
        payload_order_errors(document["payloads"])
      elsif grouped_cases?(document)
        group_name_errors(document, relative) +
          input_format_errors(document, relative) +
          case_id_errors(document["cases"]) +
          target_coverage_errors(document["targets"], document["cases"])
      elsif rejection_cases?(document)
        group_name_errors(document, relative) +
          rejection_format_errors(document, relative) +
          case_id_errors(document["cases"]) +
          rejection_index_errors(document["cases"])
      else
        []
      end
    end

    # Dispatch is on the shape a payload carries, not the schema that accepted
    # it, so a payload kind added later is skipped rather than crashing these
    # checks. For the kinds that do match, the schema has already guaranteed
    # the shape by the time this runs.
    def listed_payloads?(document)
      entries = document["payloads"]
      entries.is_a?(Array) &&
        entries.all? do |entry|
          entry.is_a?(Hash) && entry["path"].is_a?(String)
        end
    end

    def grouped_cases?(document)
      cases = document["cases"]
      document["targets"].is_a?(Array) && cases.is_a?(Array) &&
        cases.all? { |kase| kase.is_a?(Hash) && kase["expected"].is_a?(Hash) }
    end

    # The schema says `group` matches the file name without its extension; a
    # schema cannot see the file name, so the promise is kept here.
    # A rejection payload carries `cases` but no `targets`, and every case an
    # `error` instead of an `expected`. Dispatching on that shape rather than
    # on the schema keeps this in step with how `listed_payloads?` and
    # `grouped_cases?` already work.
    def rejection_cases?(document)
      cases = document["cases"]
      document["targets"].nil? && cases.is_a?(Array) &&
        cases.all? { |kase| kase.is_a?(Hash) && kase["error"].is_a?(Hash) }
    end

    # Same fact-in-several-places check as `input_format_errors`, minus the
    # schema segment: a rejection schema's middle segment is the payload KIND
    # (`rejections`), not the input format, so comparing them would report a
    # mismatch on every valid file.
    def rejection_format_errors(document, relative)
      format = document["input_format"]
      return [] unless format.is_a?(String)

      errors = []
      directory = File.dirname(relative)
      if directory != format
        errors << Error.new("/input_format",
                            "is #{format.inspect}, but the file sits in " \
                            "#{directory}/; a group lives in the directory " \
                            "named after its input format")
      end

      document["cases"].each_with_index do |kase, index|
        case_format = kase["input_format"]
        next if case_format == format

        errors << Error.new("/cases/#{index}/input_format",
                            "is #{case_format.inspect}, but the group's " \
                            "`input_format` is #{format.inspect}; a case " \
                            "does not switch formats mid-group")
      end
      errors
    end

    # `index` is an offset into `preprocessed`, so it has to be inside it.
    # `== length` is legitimate: a premature-end failure points just past the
    # last character. Past that is a position in no text, which a consumer
    # mapping offsets would read straight off the end.
    def rejection_index_errors(cases)
      cases.each_with_index.filter_map do |kase, index|
        offset = kase.dig("error", "index")
        text = kase["preprocessed"]
        next unless offset.is_a?(Integer) && text.is_a?(String)
        next unless offset > text.length

        Error.new("/cases/#{index}/error/index",
                  "is #{offset}, but `preprocessed` is #{text.length} " \
                  "character(s); the offset points outside the text it " \
                  "describes")
      end
    end

    def group_name_errors(document, relative)
      group = document["group"]
      stem = File.basename(relative, ".*")
      return [] unless group.is_a?(String) && group != stem

      [Error.new("/group",
                 "is #{group.inspect}, but the file is named " \
                 "#{File.basename(relative)}; `group` matches the file name " \
                 "without its extension")]
    end

    # A group's input format is written down four times: in the `schema`
    # value's middle segment, in the payload's own `input_format`, in the
    # directory the file sits in, and in every case. One fact, four spellings
    # — all four must agree, and a mismatch names the spelling that disagrees.
    def input_format_errors(document, relative)
      format = document["input_format"]
      return [] unless format.is_a?(String)

      errors = []
      declared = document["schema"].split("/")[1]
      if declared != format
        errors << Error.new("/input_format",
                            "is #{format.inspect}, but the payload declares " \
                            "`schema: #{document['schema']}`, whose middle " \
                            "segment is the input format")
      end

      directory = File.dirname(relative)
      if directory != format
        errors << Error.new("/input_format",
                            "is #{format.inspect}, but the file sits in " \
                            "#{directory}/; a group lives in the directory " \
                            "named after its input format")
      end

      document["cases"].each_with_index do |kase, index|
        case_format = kase["input_format"]
        next if case_format == format

        errors << Error.new("/cases/#{index}/input_format",
                            "is #{case_format.inspect}, but the group's " \
                            "`input_format` is #{format.inspect}; a case " \
                            "does not switch formats mid-group")
      end
      errors
    end

    # `id` is the join key downstream reporting uses; two cases sharing one
    # make every result ambiguous. The schema calls ids unique within the
    # group, and uniqueness across sibling items is another comparison a
    # schema cannot make.
    def case_id_errors(cases)
      first_seen = {}
      cases.each_with_index.filter_map do |kase, index|
        id = kase["id"]
        next unless id.is_a?(String)

        if (earlier = first_seen[id])
          Error.new("/cases/#{index}/id",
                    "reuses #{id.inspect}, which case #{earlier} already " \
                    "uses; ids are unique within a group")
        else
          first_seen[id] = index
          nil
        end
      end
    end

    # `targets` is declared once for the whole group, so it and every case's
    # `expected` keys are the same set: a key outside `targets` is an
    # expectation the group never declared, and a target with no key is a
    # promise the case does not keep.
    def target_coverage_errors(targets, cases)
      cases.each_with_index.flat_map do |kase, index|
        expected = kase["expected"].keys
        id = kase["id"]

        (expected - targets).sort.map do |target|
          Error.new("/cases/#{index}/expected/#{target}",
                    "case `#{id}` expects `#{target}`, which is not one of " \
                    "the group's targets (#{targets.join(', ')})")
        end +
          (targets - expected).sort.map do |target|
            Error.new("/cases/#{index}/expected",
                      "case `#{id}` carries no expectation for `#{target}`, " \
                      "which the group lists in `targets`")
          end
      end
    end

    # The provenance says `payloads` is sorted by path, and a diff of the corpus
    # is only readable while it stays that way.
    def payload_order_errors(payloads)
      paths = payloads.map { |entry| entry["path"] }
      paths.each_cons(2).with_index.filter_map do |(previous, current), index|
        next if current >= previous

        Error.new("/payloads/#{index + 1}/path",
                  "records #{current} after #{previous}; " \
                  "`payloads` is sorted by path")
      end
    end

    def count_of(document)
      cases = document["cases"]
      if cases.is_a?(Array)
        return "#{cases.length} case#{'s' unless cases.length == 1}"
      end

      payloads = document["payloads"]
      if payloads.is_a?(Array)
        return "#{payloads.length} payload#{'s' unless payloads.length == 1}"
      end

      "ok"
    end

    # YAML happily reads `.nan` and `.inf`, but JSON has no way to write them
    # back, and these payloads exist for ordinary JSON Schema consumers.
    # Rejected before schema evaluation: to a type check a NaN is just a
    # number, so the schema would wave it through.
    def nonfinite_errors(value, path)
      case value
      when Float
        return [] if value.finite?

        label = value.nan? ? "NaN" : value.to_s
        [Error.new(path, "is #{label}, which JSON cannot represent; corpus " \
                         "values are limited to what a JSON parser can read")]
      when Array
        value.each_with_index.flat_map do |item, index|
          nonfinite_errors(item, "#{path}/#{index}")
        end
      when Hash
        value.flat_map do |key, item|
          pointer = "#{path}/#{pointer_token(key)}"
          nonfinite_errors(key, pointer) + nonfinite_errors(item, pointer)
        end
      else
        []
      end
    end

    # A JSON-pointer token for a key that, this early, may not even be a
    # string yet — the schema rejects non-string keys later. Escaping applies
    # to whatever token is produced: a non-string key's `inspect` can carry
    # `~` or `/` too, and an unescaped one renders an ambiguous pointer.
    def pointer_token(key)
      token = key.is_a?(String) ? key : JsonSchema.truncate(key)
      token.gsub("~", "~0").gsub("/", "~1")
    end

    # `aliases: false` is a check, not a precaution: an anchor would make the
    # payload unreadable to a parser that does not resolve them.
    def load_yaml(path)
      YAML.safe_load_file(path, aliases: false)
    rescue Psych::Exception => e
      failure(display(path),
              [Error.new("", "is not portable YAML: #{e.class}: #{e.message}")])
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
        message = "is missing; without it every payload here is " \
                  "unattributed and unreproducible"
        return failure(display(expected), [Error.new("", message)])
      end
      if @provenance_paths.length > 1
        listed = @provenance_paths.map { |path| display(path) }.join(", ")
        message = "the corpus has one provenance document, but " \
                  "#{@provenance_paths.length} declare it: #{listed}"
        return failure(display(expected), [Error.new("", message)])
      end

      path = @provenance_paths.first
      document = @provenance[path]
      return if document.nil? # it failed its schema; there is nothing to trust

      shown = display(path)
      errors = []
      unless File.expand_path(path) == File.expand_path(expected)
        errors << Error.new("",
                            "must be the corpus root's #{display(expected)}, " \
                            "since `payloads` paths are relative to it")
      end

      unrecorded = check_payloads(document, errors)
      failure(shown, errors) unless errors.empty?
      unrecorded.each do |file|
        failure(display(file),
                [Error.new("", "is not recorded in #{shown}; every payload " \
                               "has a `payloads` entry")])
      end
    end

    # Fills `errors` with what the provenance gets wrong, and returns the
    # payload files it never mentions.
    def check_payloads(document, errors)
      on_disk = payload_files
      recorded = {}

      document["payloads"].each_with_index do |entry, index|
        pointer = "/payloads/#{index}"
        name = entry["path"]
        if recorded.key?(name)
          next errors << Error.new("#{pointer}/path",
                                   "records #{name} a second time")
        end

        recorded[name] = true
        file = File.expand_path(File.join(@corpus_root, name))
        unless on_disk.include?(file)
          next errors << Error.new("#{pointer}/path",
                                   "records #{name}, which is not a payload " \
                                   "in #{display(@corpus_root)}")
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

    # Identical (path, message) pairs collapse to one line: two rules can
    # legitimately reach the same complaint, and repeating it informs nobody.
    def failure(shown, errors)
      @report.fail!
      errors = errors.uniq
      puts "  FAIL  #{shown}"
      errors.first(25).each { |error| puts "          #{error}" }
      puts "          ... #{errors.length - 25} more" if errors.length > 25
      nil
    end

    # The README states the corpus's size and its group inventory in prose, and
    # prose drifts. It has already drifted twice: it claimed 70 cases in 13
    # groups while the corpus held 76 in 14, and then 91 in 18. A consumer
    # deciding whether this corpus covers their format reads exactly those
    # numbers, so a stale one is a false claim about a shared contract — the
    # same class of defect as a wrong schema description, and worth failing on.
    def check_readme
      path = File.join(File.dirname(@corpus_root), "README.adoc")
      return unless File.file?(path)

      text = File.read(path)
      errors = readme_count_errors(text) + readme_group_errors(text)
      return failure(relative_to_corpus(path), errors) if errors.any?

      puts "  OK    #{'README.adoc'.ljust(52)} counts and group inventory match the corpus"
    end

    def readme_count_errors(text)
      errors = []
      actual_cases = positive_cases.length
      actual_groups = positive_groups.length

      stated = text[/^\| AsciiMath\s+\|[^|]*?(\d+) cases, (\d+) groups/, 0]
      if stated.nil?
        errors << "no \"N cases, N groups\" claim found in the coverage table"
      else
        cases, groups = text.match(/^\| AsciiMath\s+\|[^|]*?(\d+) cases, (\d+) groups/)[1..2].map(&:to_i)
        errors << "coverage table says #{cases} cases, corpus has #{actual_cases}" if cases != actual_cases
        errors << "coverage table says #{groups} groups, corpus has #{actual_groups}" if groups != actual_groups
      end

      text.scan(/checked for all (\d+)/).flatten.map(&:to_i).uniq.each do |claimed|
        errors << "coverage table says \"checked for all #{claimed}\", corpus has #{actual_cases}" if claimed != actual_cases
      end
      errors
    end

    def readme_group_errors(text)
      listed = text.scan(/`([a-z][a-z0-9-]*)`\s+(\d+)/).to_h { |name, n| [name, n.to_i] }
      return ["no group inventory found"] if listed.empty?

      actual = positive_groups
      errors = []
      (actual.keys - listed.keys).sort.each { |name| errors << "group inventory omits `#{name}` (#{actual[name]} cases)" }
      (listed.keys - actual.keys).sort.each { |name| errors << "group inventory lists `#{name}`, which the corpus does not have" }
      (actual.keys & listed.keys).sort.each do |name|
        errors << "group inventory says `#{name}` #{listed[name]}, corpus has #{actual[name]}" if listed[name] != actual[name]
      end
      errors
    end

    # Positive (renderable) payloads only: a rejection group has no expectations
    # and is counted separately everywhere else too.
    def positive_groups
      @positive_groups ||= payload_files.each_with_object({}) do |path, groups|
        document = YAML.safe_load_file(path)
        # Positive payloads are every payload kind EXCEPT rejections; matching
        # on a "cases/" segment was wrong, because the case schema is named for
        # its input format (`plurimath-corpus/asciimath/1`).
        schema = document.is_a?(::Hash) ? document["schema"].to_s : ""
        next if schema.empty? || schema.include?("rejections/")

        groups[document["group"].to_s] = Array(document["cases"]).length
      end
    end

    def positive_cases
      @positive_cases ||= positive_groups.values.sum.then { |n| ::Array.new(n) }
    end

    def summary
      counts = "#{@report.files} file#{'s' unless @report.files == 1}: " \
               "#{@report.payloads} " \
               "payload#{'s' unless @report.payloads == 1} " \
               "(#{@report.cases} case#{'s' unless @report.cases == 1}), " \
               "#{@report.provenance} provenance"
      if @report.failures.zero?
        puts "#{counts} — all valid"
      else
        failed = @report.failures
        puts "#{counts} — #{failed} file#{'s' unless failed == 1} failed"
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

      Validates every corpus file against the schema it declares. A file the
      corpus layout does not allow (anything but provenance.yaml and
      <input-format>/<group>.yaml payloads) fails the run rather than being
      skipped.

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
          value = argv.shift or raise Failure, "--schema needs a directory"
          options[:schema_dir] = value
        when /\A--schema=(.*)\z/
          options[:schema_dir] = Regexp.last_match(1)
        when /\A-/ then raise Failure, "unknown option #{argument}\n\n#{USAGE}"
        else positional << argument
        end
      end

      if positional.length > 1
        raise Failure,
              "expected at most one corpus root, got #{positional.length}"
      end

      options[:corpus_root] = positional.first if positional.first

      Runner.new(**options).run
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit Testsuite::CLI.run(ARGV)
  rescue Testsuite::Failure, Errno::ENOENT => e
    warn "validate: #{e.message}"
    exit 2
  end
end
