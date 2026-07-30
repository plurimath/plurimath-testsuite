# frozen_string_literal: true

# Generates the AsciiMath conformance corpus and the node census from the Ruby
# plurimath gem, which is the oracle (ARCHITECTURE.md §1).
#
# Usage, from the plurimath-ts repository root:
#
#   BUNDLE_GEMFILE=/path/to/plurimath/Gemfile \
#     mise x -- bundle exec ruby scripts/generate-corpus.rb
#
# Options:
#   --gem PATH       gem checkout to treat as the oracle
#                    (default: the checkout bundler resolved `plurimath` from)
#   --out PATH       output root (default: <repo>/corpus)
#   --allow-dirty    generate from a dirty checkout; the output is marked
#                    non-committable in every sidecar manifest (§7)
#   --help
#
# Outputs (payload + sidecar manifest per payload, §7):
#   corpus/asciimath/<group>.yaml   conformance cases, grouped by feature
#   corpus/census.yaml              every Math::Core descendant, classified
#   corpus/exclusions.yaml          cases withheld because of a deferred feature
#   corpus/**/<payload>.manifest.yaml
#
# The generator is deterministic: two runs over the same oracle produce
# byte-identical output. No timestamps, no absolute paths, sorted keys.

require "plurimath"
require "digest"
require "fileutils"
require "yaml"

module CorpusGenerator
  REPO_ROOT = File.expand_path("..", __dir__)
  GENERATOR_PATH = "scripts/generate-corpus.rb"

  CORPUS_SCHEMA = "plurimath-corpus/asciimath/1"
  CENSUS_SCHEMA = "plurimath-corpus/census/1"
  EXCLUSIONS_SCHEMA = "plurimath-corpus/exclusions/1"
  MANIFEST_SCHEMA = "plurimath-corpus/manifest/1"

  INPUT_FORMAT = "asciimath"
  TARGET_FORMATS = %w[asciimath latex mathml].freeze

  # Deferred features are matched on the INPUT TEXT, never on a parsed class:
  # the gem raises while constructing an invalid UnitsML node, so no formula
  # exists to inspect for the rejection cases (ARCHITECTURE.md §5).
  DEFERRED_INPUT_PATTERNS = {
    "unitsml" => /unitsml\(/,
  }.freeze

  # Classes the port deliberately does not implement (§5). A deferred class may
  # never appear in a generated case; that invariant is checked, not assumed.
  DEFERRED_CLASSES = %w[
    Math::Function::Unitsml
  ].freeze

  # The direct `Math::Core` descendants. Each is a structural family the port
  # models in its own right. A new direct descendant is an unclassified new
  # family and fails generation.
  FAMILY_ROOTS = %w[
    Math::Formula
    Math::Function::BinaryFunction
    Math::Function::Nary
    Math::Function::Table
    Math::Function::TernaryFunction
    Math::Function::UnaryFunction
    Math::Function::Unitsml
    Math::Number
    Math::Symbols::Symbol
  ].freeze

  # Base classes the gem never instantiates. Declared, then machine-checked:
  # each must still have subclasses, must never be constructed anywhere in the
  # gem's own source, and must not appear in any generated case.
  ABSTRACT_CLASSES = %w[
    Math::Function::BinaryFunction
    Math::Function::TernaryFunction
    Math::Function::UnaryFunction
    Math::Symbols::Paren
  ].freeze

  # Receiver methods in an `==` body that test identity rather than compare a
  # field.
  EQUALITY_NON_FIELDS = %w[class is_a? kind_of? instance_of? respond_to?].freeze

  # Helpers an `==` body applies to the whole operand before comparing, mapped
  # to the field they read. An unlisted helper fails generation, so a new
  # upstream normalizer cannot silently drop a field from the projection.
  EQUALITY_WHOLE_OPERAND_HELPERS = {
    "comparable_value" => "value",
  }.freeze

  # Ivar prefixes `Core#variables` itself rejects: framework bookkeeping, not
  # model state.
  NON_FIELD_IVAR_PREFIXES = %w[@__ @lutaml].freeze
  NON_FIELD_IVARS = %w[@using_default].freeze

  # Seed corpus. Ids are stable and hand-assigned: they are the join key
  # between the payload, the exclusion manifest, and the TypeScript suite, so
  # they must not move when a case is inserted.
  GROUPS = [
    ["numbers", "Integer and decimal literals", [
      ["number-integer", "2"],
      ["number-decimal", "2.5"],
      ["number-zero", "0"],
      ["number-multi-digit", "123"],
      ["number-decimal-long", "3.14159"],
    ]],
    ["symbols", "Bare identifiers, Greek letters and named constants", [
      ["symbol-latin-x", "x"],
      ["symbol-greek-alpha", "alpha"],
      ["symbol-greek-pi", "pi"],
      ["symbol-greek-sigma", "sigma"],
      ["symbol-infinity", "oo"],
      ["symbol-adjacent-letters", "xyz"],
      ["symbol-spaced-letters", "x y"],
    ]],
    ["operators", "Binary operators and implicit multiplication", [
      ["operator-plus", "x + y"],
      ["operator-implicit-product", "2x"],
      ["operator-asterisk", "a*b"],
      ["operator-minus", "a - b"],
      ["operator-equals", "x = y"],
      ["operator-plus-chain", "a + b + c"],
    ]],
    ["fences", "Fenced groups and separators", [
      ["fence-round-single", "(x)"],
      ["fence-round-expression", "(x+y)"],
      ["fence-square-pair", "[a,b]"],
      ["fence-curly-single", "{x}"],
      ["fence-round-triple", "(a,b,c)"],
      ["fence-over-number", "(x+y)/2"],
    ]],
    ["frac", "Fractions, written both with `/` and with `frac`", [
      ["frac-simple", "a/b"],
      ["frac-numeric", "2/3"],
      ["frac-fenced-numerator", "(a+b)/c"],
      ["frac-fenced-denominator", "x/(y+z)"],
      ["frac-sum-of-fracs", "a/b + c/d"],
      ["frac-explicit", "frac(a)(b)"],
    ]],
    ["powers", "Superscripts and subscripts", [
      ["power-square", "x^2"],
      ["power-fenced-exponent", "x^(n+1)"],
      ["subscript-digit", "a_1"],
      ["subscript-fenced", "a_(n+1)"],
      ["power-and-subscript", "x_1^2"],
      ["power-exponential", "e^x"],
      ["power-of-two", "2^10"],
      ["power-over-number", "x^2/4"],
    ]],
    ["roots", "Square roots and nth roots", [
      ["root-sqrt-number", "sqrt(2)"],
      ["root-sqrt-expression", "sqrt(x+1)"],
      ["root-sqrt-pythagoras", "sqrt(a^2 + b^2)"],
      ["root-cube", "root(3)(x+1)"],
    ]],
    ["unary-functions", "Unary functions, accented and fenced forms", [
      ["unary-sin-fenced", "sin(x)"],
      ["unary-sin-bare", "sin x"],
      ["unary-cos-product", "cos(2x)"],
      ["unary-abs", "abs(x)"],
      ["unary-hat", "hat(x)"],
      ["unary-bar", "bar(x)"],
      ["unary-vec", "vec(v)"],
    ]],
    ["quoted-text", "Literal text, quoted and via `text`", [
      ["text-function", "text(hello)"],
      ["text-quoted", "\"hello world\""],
      ["text-unitsml-valid", "\"unitsml(kg)\""],
      ["text-unitsml-invalid", "\"unitsml(zzz)\""],
    ]],
    ["nary", "n-ary operators and limit-bearing functions", [
      ["nary-log-base", "log_2 8"],
      ["nary-lim", "lim_(x->oo) f(x)"],
      ["nary-sum-bounded", "sum_(i=1)^n i"],
      ["nary-int-bounded", "int_0^1 x dx"],
      ["nary-prod-bounded", "prod_(k=1)^n k"],
      ["nary-sum-bare", "sum x"],
    ]],
    ["matrices", "Tables and matrices", [
      ["matrix-column", "((a),(b))"],
      ["matrix-two-by-two", "[[a,b],[c,d]]"],
    ]],
    ["mixed", "Whole expressions combining several features", [
      ["mixed-implicit-product", "2pi r"],
      ["mixed-greek-sequence", "alpha beta gamma"],
      ["mixed-function-definition", "f(x) = x^2"],
      ["mixed-binomial-square", "(x+y)^2 = x^2 + 2xy + y^2"],
      ["mixed-sum-of-cubes", "sum_(i=1)^n i^3=((n(n+1))/2)^2"],
    ]],
    ["whitespace", "Whitespace runs, which exercise one-character matching", [
      ["whitespace-around-operator", "x  +  y"],
      ["whitespace-between-letters", "a   b"],
      ["whitespace-in-subscript", "sum_(i = 1)^n  i"],
      ["whitespace-surrounding", " x "],
      ["whitespace-inside-fence", "sqrt( x )"],
    ]],
  ].freeze

  class Error < StandardError; end

  module_function

  # --- shell out to git, read-only ----------------------------------------

  def git(dir, *args)
    output = IO.popen(["git", "-C", dir, *args], err: File::NULL, &:read)
    raise Error, "git #{args.join(' ')} failed in #{dir}" unless $?.success?

    output
  end

  def git_repository?(dir)
    IO.popen(["git", "-C", dir, "rev-parse", "--git-dir"],
             err: File::NULL, &:read)
    $?.success?
  end

  # Paths under `except` are ignored. The generator's own output cannot make
  # the run unreproducible — it is overwritten — and excluding it is what lets
  # a committed corpus be regenerated and diffed (§7).
  def dirty_paths(dir, except: [])
    git(dir, "status", "--porcelain").lines.filter_map do |line|
      path = line[3..].to_s.strip
      path = path.split(" -> ").last.to_s.strip if path.include?(" -> ")
      path = path.delete_prefix('"').delete_suffix('"')
      next if except.any? { |p| path == p || path.start_with?("#{p}/") }

      path
    end.sort
  end

  # --- provenance ----------------------------------------------------------

  def sha256(content)
    Digest::SHA256.hexdigest(content)
  end

  def checkout_provenance(dir, dirty)
    {
      "commit" => git(dir, "rev-parse", "HEAD").strip,
      "clean" => dirty.empty?,
      "dirty_paths" => dirty,
    }
  end

  def lockfile_path(gem_dir)
    path = File.join(gem_dir, "Gemfile.lock")
    return path if File.file?(path)

    raise Error, <<~MESSAGE
      No Gemfile.lock in #{gem_dir}.
      Run `mise x -- bundle install` there first; §7 records its checksum.
    MESSAGE
  end

  # A deliberately small Gemfile.lock reader: enough to record each dependency
  # by source kind (§7), not a general lockfile parser.
  def parse_lockfile(path)
    sources = []
    specs = {}
    current = nil
    bundled_with = nil
    platforms = []
    in_specs = false
    in_bundled = false

    File.readlines(path, chomp: true).each do |line|
      if line.match?(/\A\S/)
        in_specs = false
        in_bundled = line == "BUNDLED WITH"
        current = nil
        case line
        when "PATH", "GIT", "GEM"
          current = { "kind" => line.downcase, "specs" => [] }
          sources << current
        end
        next
      end

      if in_bundled
        bundled_with ||= line.strip
        next
      end

      if current
        if line.match?(/\A {2}\S+:/)
          # Split on ":" alone, not ": " — a bare "specs:" has no trailing
          # space, and splitting on ": " leaves the colon stuck to the key.
          key, value = line.strip.split(":", 2)
          value = value.to_s.strip
          in_specs = key == "specs"
          current[key] = value unless value.empty?
        elsif in_specs && line.match?(/\A {4}\S/)
          name, version = line.strip.match(/\A(\S+) \((.+)\)\z/)&.captures
          next unless name

          version, platform = version.split("-", 2)
          spec = { "name" => name, "version" => version,
                   "platform" => platform || "ruby", "source" => current }
          current["specs"] << name
          specs[name] = spec
        end
      elsif line.match?(/\A {2}\S/)
        platforms << line.strip
      end
    end

    { sources: sources, specs: specs, platforms: platforms.sort.uniq,
      bundled_with: bundled_with }
  end

  def dependency_provenance(gem_dir, gem_spec)
    path = lockfile_path(gem_dir)
    lock = parse_lockfile(path)

    external_path_sources = lock[:sources].select do |source|
      source["kind"] == "path" && source["remote"] != "."
    end

    direct = gem_spec.dependencies.select { |d| d.type == :runtime }
      .map(&:name).sort.map do |name|
      spec = lock[:specs][name]
      raise Error, "#{name} is not resolved in #{path}" unless spec

      entry = {
        "name" => spec["name"],
        "version" => spec["version"],
        "platform" => spec["platform"],
        "source_kind" => spec["source"]["kind"],
        "source" => spec["source"]["remote"],
      }
      entry["revision"] = spec["source"]["revision"] if spec["source"]["revision"]
      entry
    end

    {
      provenance: {
        "lockfile" => {
          "path" => "Gemfile.lock",
          "sha256" => sha256(File.binread(path)),
          "resolved_gems" => lock[:specs].size,
          "platforms" => lock[:platforms],
          "bundler" => lock[:bundled_with],
        },
        "sources" => lock[:sources].map do |source|
          entry = { "kind" => source["kind"], "remote" => source["remote"],
                    "gems" => source["specs"].sort }
          entry["revision"] = source["revision"] if source["revision"]
          entry
        end,
        "direct_runtime" => direct,
      },
      external_path_sources: external_path_sources.map { |s| s["remote"] },
    }
  end

  def configuration_provenance
    configuration = Plurimath.configuration
    defaults = {
      "locale" => nil,
      "number_formatter" => nil,
      "evaluation_max_iterations" => Plurimath::Configuration::DEFAULT_MAX_ITERATIONS,
      "decimal" => Plurimath::Configuration::DEFAULT_DECIMAL,
    }
    actual = {
      "locale" => configuration.locale&.to_s,
      "number_formatter" => configuration.number_formatter&.class&.name,
      "evaluation_max_iterations" => configuration.evaluation_max_iterations,
      "decimal" => configuration.decimal,
    }
    actual.reject { |key, value| defaults[key] == value }
  end

  def require_ox_engine!
    engine = Plurimath.xml_engine
    return if engine.to_s == "Plurimath::XmlEngine::OxEngine"

    raise Error, <<~MESSAGE
      Canonical payloads are generated with Ox; this process loaded #{engine}.
      Unset PLURIMATH_OGA and re-run. Oga is a parity check only (§7).
    MESSAGE
  end

  # --- deferred features ---------------------------------------------------

  def deferred_feature_for(input)
    DEFERRED_INPUT_PATTERNS.find { |_feature, pattern| input.match?(pattern) }&.first
  end

  # --- serialization -------------------------------------------------------

  def class_key(klass)
    klass.name.to_s.sub("Plurimath::", "")
  end

  def serialize_hash(hash, path)
    result = {}
    hash.each do |key, value|
      name = key.to_s
      raise Error, "duplicate key #{name.inspect} at #{path}" if result.key?(name)

      result[name] = serialize_value(value, "#{path}.#{name}")
    end
    result.sort.to_h
  end

  # Fails on an unrecognized type rather than falling back to `to_s`: an
  # unserializable field is a corpus gap, and a silent `to_s` would hide it.
  def serialize_value(value, path)
    case value
    when nil, true, false, ::String, ::Integer, ::Float then value
    when ::Symbol then value.to_s
    when ::Parslet::Slice then value.to_s
    when ::Array then value.each_with_index.map { |v, i| serialize_value(v, "#{path}[#{i}]") }
    when ::Hash then serialize_hash(value, path)
    when Plurimath::Math::Core then serialize_node(value, path)
    else
      raise Error, "cannot serialize #{value.class} at #{path}"
    end
  end

  def serialize_node(node, path)
    name = class_key(node.class)
    fields = node.variables.sort.to_h do |ivar|
      field = ivar.to_s.delete_prefix("@")
      [field, serialize_value(node.get(ivar), "#{path}.#{field}")]
    end
    { "class" => name, "fields" => fields }
  end

  def serialize_tree(node, path)
    case node
    when nil, true, false, ::String, ::Integer, ::Float then node
    when ::Symbol then node.to_s
    when ::Parslet::Slice then node.to_s
    when ::Array then node.each_with_index.map { |n, i| serialize_tree(n, "#{path}[#{i}]") }
    when ::Hash
      node.to_h { |key, value| [key.to_s, serialize_tree(value, "#{path}.#{key}")] }
    else
      raise Error, "cannot serialize parse tree node #{node.class} at #{path}"
    end
  end

  def node_classes(value, acc = [])
    case value
    when Plurimath::Math::Core
      acc << class_key(value.class)
      value.variables.each { |ivar| node_classes(value.get(ivar), acc) }
    when ::Array then value.each { |v| node_classes(v, acc) }
    when ::Hash then value.each_value { |v| node_classes(v, acc) }
    end
    acc
  end

  # --- corpus --------------------------------------------------------------

  def build_case(id, input)
    formula = Plurimath::Math.parse(input, INPUT_FORMAT.to_sym)
    preprocessed = Plurimath::Asciimath::Parser.new(input).text
    tree = Plurimath::Asciimath::Parse.new.parse(preprocessed)

    {
      "id" => id,
      "input" => input,
      "input_format" => INPUT_FORMAT,
      "preprocessed" => preprocessed,
      "expected" => {
        "asciimath" => formula.to_asciimath,
        "latex" => formula.to_latex,
        "mathml" => formula.to_mathml,
      },
      "parse_tree" => serialize_tree(tree, id),
      "model" => serialize_node(formula, id),
      "_classes" => node_classes(formula).uniq.sort,
    }
  end

  def build_corpus
    groups = []
    exclusions = []

    GROUPS.each do |name, description, cases|
      built = cases.filter_map do |id, input|
        feature = deferred_feature_for(input)
        if feature
          exclusions << {
            "id" => id,
            "group" => name,
            "input" => input,
            "input_format" => INPUT_FORMAT,
            "feature" => feature,
            "matched" => DEFERRED_INPUT_PATTERNS.fetch(feature).source,
            "reason" => "#{feature} is deferred (ARCHITECTURE.md §5); matched " \
                        "on the input text, since the gem raises for invalid " \
                        "#{feature} and produces no formula to inspect",
          }
          next
        end

        begin
          build_case(id, input)
        rescue StandardError => e
          raise Error, "case #{id} (#{input.inspect}) failed: #{e.class}: #{e.message}"
        end
      end

      groups << [name, description, built]
    end

    [groups, exclusions]
  end

  # --- census --------------------------------------------------------------

  def all_descendants(klass, acc = [])
    (klass.descendants || []).sort_by(&:name).each do |descendant|
      acc << descendant
      all_descendants(descendant, acc)
    end
    acc
  end

  # Force-loads the autoloaded model namespaces so `descendants` is complete.
  def load_model_classes!(gem_dir)
    Dir.glob(File.join(gem_dir, "lib/plurimath/math/**/*.rb")).sort.each do |file|
      require file
    end
  end

  def source_body(path, line_index)
    lines = File.readlines(path, chomp: true)
    opening = lines[line_index]
    raise Error, "no source at #{path}:#{line_index + 1}" unless opening

    indent = opening[/\A\s*/]
    body = [opening]
    ((line_index + 1)...lines.length).each do |i|
      body << lines[i]
      break if lines[i] == "#{indent}end"
    end
    body
  end

  def class_body(klass)
    location = Object.const_source_location(klass.name)
    unless location && location.first
      raise Error, "cannot locate the source of #{klass.name}"
    end

    source_body(location.first, location.last - 1)
  end

  def declared_fields(klass)
    fields = []
    body = class_body(klass)
    collecting = false

    body.each do |line|
      if collecting
        fields.concat(line.scan(/:([a-z_][A-Za-z0-9_]*)/).flatten)
        collecting = line.rstrip.end_with?(",")
        next
      end

      if line.match?(/\A\s*attr_(accessor|reader|writer)\s/)
        fields.concat(line.scan(/:([a-z_][A-Za-z0-9_]*)/).flatten)
        collecting = line.rstrip.end_with?(",")
      end

      line.scan(/(@[a-z_][A-Za-z0-9_]*)\s*=(?![=~>])/).flatten.each do |ivar|
        next if NON_FIELD_IVARS.include?(ivar)
        next if NON_FIELD_IVAR_PREFIXES.any? { |prefix| ivar.start_with?(prefix) }

        fields << ivar.delete_prefix("@")
      end
    end

    fields.uniq.sort
  end

  def equality_owner(klass)
    owner = klass.instance_method(:==).owner
    owner < Plurimath::Math::Core || owner == Plurimath::Math::Core ? owner : nil
  end

  def equality_definition(owner)
    location = owner.instance_method(:==).source_location
    raise Error, "cannot locate #{owner.name}#==" unless location

    body = source_body(location.first, location.last - 1)
    source = body.join("\n")
    indent = body.first[/\A\s*/]
    trimmed = body.map { |line| line.start_with?(indent) ? line[indent.length..] : line }

    normalized = {}
    source.scan(/([a-z_][A-Za-z0-9_]*)\((?:object|other)&?\.([a-z_][A-Za-z0-9_]*)\)/)
      .each { |helper, field| normalized[field] = helper }
    source.scan(/([a-z_][A-Za-z0-9_]*)\((?:object|other)\)/).each do |(helper)|
      field = EQUALITY_WHOLE_OPERAND_HELPERS[helper]
      unless field
        raise Error, <<~MESSAGE
          #{owner.name}#== applies the unclassified helper `#{helper}` to the
          whole operand. Add it to EQUALITY_WHOLE_OPERAND_HELPERS with the field
          it reads, so the equality projection stays complete.
        MESSAGE
      end

      normalized[field] = helper
    end

    fields = source.scan(/(?:object|other)&?\.([a-z_][A-Za-z0-9_]*[?!]?)/).flatten
    fields -= EQUALITY_NON_FIELDS
    fields = (fields + normalized.keys).uniq.sort

    {
      "class" => class_key(owner),
      "compares_class" => source.match?(/(?:object|other)\.class\s*==|==\s*(?:object|other)\.class/),
      "calls_super" => source.match?(/(?<![.\w])super(?![\w])/) ? true : false,
      "own_fields" => fields,
      "normalized_by" => normalized.sort.to_h,
      "source" => trimmed.join("\n"),
    }
  end

  # Every `==` an entry can reach, including the ancestors its `super` calls
  # delegate to, flattened to the fields each projection effectively compares.
  def equality_definitions(classes)
    pending = classes.filter_map { |klass| equality_owner(klass) }.uniq
    definitions = {}

    until pending.empty?
      owner = pending.shift
      key = class_key(owner)
      next if definitions.key?(key)

      definition = equality_definition(owner)
      definitions[key] = definition
      next unless definition["calls_super"]

      parent = equality_owner(owner.superclass)
      unless parent
        raise Error, "#{owner.name}#== calls super outside the model hierarchy"
      end

      definition["super"] = class_key(parent)
      pending << parent
    end

    definitions.each_key do |key|
      definitions[key]["fields"] = effective_equality_fields(definitions, key)
    end
    definitions.sort.to_h
  end

  def effective_equality_fields(definitions, key, seen = [])
    raise Error, "cyclic super chain at #{key}" if seen.include?(key)

    definition = definitions.fetch(key)
    fields = definition["own_fields"].dup
    if definition["super"]
      fields += effective_equality_fields(definitions, definition["super"], seen + [key])
    end
    fields.uniq.sort
  end

  def abstract_check!(gem_dir, descendants)
    by_key = descendants.to_h { |klass| [class_key(klass), klass] }
    sources = Dir.glob(File.join(gem_dir, "lib/**/*.rb")).sort
      .map { |file| File.read(file) }

    ABSTRACT_CLASSES.each do |key|
      klass = by_key[key]
      raise Error, "declared-abstract #{key} is not a Math::Core descendant" unless klass

      if (klass.descendants || []).empty?
        raise Error, "declared-abstract #{key} has no subclasses; reclassify it"
      end

      short = klass.name.split("::").last
      pattern = /(?<![A-Za-z0-9_])#{Regexp.escape(short)}\.new(?![A-Za-z0-9_])/
      next unless sources.any? { |source| source.match?(pattern) }

      raise Error, "declared-abstract #{key} is instantiated in the gem; reclassify it"
    end
  end

  def build_census(gem_dir)
    descendants = all_descendants(Plurimath::Math::Core).uniq
    abstract_check!(gem_dir, descendants)

    direct = Plurimath::Math::Core.descendants.map { |k| class_key(k) }.uniq.sort
    unknown = direct - FAMILY_ROOTS
    unless unknown.empty?
      raise Error, <<~MESSAGE
        Unclassified new model #{unknown.length == 1 ? 'family' : 'families'}: #{unknown.join(', ')}.
        A direct Math::Core descendant is a structural family the port must
        model. Add it to FAMILY_ROOTS once its disposition is decided.
      MESSAGE
    end

    definitions = equality_definitions(descendants)
    own_fields = descendants.to_h { |klass| [klass, declared_fields(klass)] }

    inherited_fields = lambda do |klass|
      fields = []
      current = klass.superclass
      while current && current != Plurimath::Math::Core
        fields += own_fields.fetch(current, [])
        current = current.superclass
      end
      fields.uniq
    end

    own_equality = descendants.to_h { |klass| [klass, equality_owner(klass) == klass] }
    new_fields = descendants.to_h do |klass|
      [klass, own_fields.fetch(klass) - inherited_fields.call(klass)]
    end

    disposition_of = lambda do |klass|
      key = class_key(klass)
      if DEFERRED_CLASSES.include?(key) then "deferred"
      elsif FAMILY_ROOTS.include?(key) then "implemented"
      elsif !new_fields.fetch(klass).empty? || own_equality.fetch(klass) then "implemented"
      else "aliased"
      end
    end

    entries = descendants.sort_by(&:name).map do |klass|
      disposition = disposition_of.call(klass)
      entry = {
        "name" => class_key(klass),
        "parent" => class_key(klass.superclass),
        "disposition" => disposition,
        "abstract" => ABSTRACT_CLASSES.include?(class_key(klass)),
        "direct_subclasses" => (klass.descendants || []).uniq.length,
      }

      if disposition == "aliased"
        target = klass.superclass
        target = target.superclass while disposition_of.call(target) == "aliased"
        entry["aliases"] = class_key(target)
      else
        owner = equality_owner(klass)
        entry["fields"] = (own_fields.fetch(klass) + inherited_fields.call(klass)).uniq.sort
        entry["own_fields"] = new_fields.fetch(klass)
        entry["equality"] = {
          "defined_by" => class_key(owner),
          "fields" => definitions.fetch(class_key(owner))["fields"],
        }
      end

      entry
    end

    counts = entries.group_by { |e| e["disposition"] }.transform_values(&:length)

    {
      "schema" => CENSUS_SCHEMA,
      "root" => class_key(Plurimath::Math::Core),
      "policy" => {
        "dispositions" => {
          "implemented" => "The port models this class: it is a family root, " \
                           "adds a field, or compares differently from its parent.",
          "aliased" => "Adds no field and no equality of its own; the port " \
                       "represents it as its alias target plus a name.",
          "deferred" => "Deliberately not implemented (ARCHITECTURE.md §5). " \
                        "A deferred class may not appear in any generated case.",
        },
        "fails_generation_on" => [
          "a direct Math::Core descendant that is not a declared family root",
          "a declared-abstract class that has no subclasses or is instantiated " \
          "in the gem",
          "a class whose source, fields or `==` cannot be read",
          "an `==` helper applied to the whole operand that is not classified",
          "a deferred class appearing in a generated corpus case",
        ],
        "family_roots" => FAMILY_ROOTS,
        "abstract" => ABSTRACT_CLASSES,
        "deferred" => DEFERRED_CLASSES,
      },
      "summary" => {
        "total" => entries.length,
        "implemented" => counts.fetch("implemented", 0),
        "aliased" => counts.fetch("aliased", 0),
        "deferred" => counts.fetch("deferred", 0),
        "abstract" => entries.count { |e| e["abstract"] },
        "concrete" => entries.count { |e| !e["abstract"] },
      },
      "equality_definitions" => definitions,
      "classes" => entries,
    }
  end

  # --- output --------------------------------------------------------------

  # Rebuilds a structure so no two nodes are the same object, which is what
  # makes Psych emit anchors and aliases.
  def unshare(value)
    case value
    when Hash then value.to_h { |k, v| [unshare(k), unshare(v)] }
    when Array then value.map { |v| unshare(v) }
    when String then value.dup
    else value
    end
  end

  def dump_yaml(data)
    # Psych emits YAML anchors/aliases whenever one object is referenced twice.
    # The corpus is consumed by parsers in other languages, so the payload must
    # be self-contained. Marshal is no help here — it preserves shared
    # references by design — so rebuild the structure to break identity.
    data = unshare(data)
    yaml = Psych.dump(data, line_width: -1)
    round_trip = Psych.safe_load(yaml, aliases: false)
    raise Error, "YAML round-trip changed the payload" unless round_trip == data

    yaml
  end

  def write_payload(path, header, data)
    body = "#{header}#{dump_yaml(data)}"
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, body)
    body
  end

  def write_manifest(payload_path, payload_bytes, out_root, provenance)
    manifest = provenance.merge(
      "payload" => {
        "path" => relative(payload_path, out_root),
        "sha256" => sha256(payload_bytes),
        "bytes" => payload_bytes.bytesize,
      },
    )
    path = "#{payload_path.delete_suffix('.yaml')}.manifest.yaml"
    File.binwrite(path, "#{manifest_header}#{dump_yaml(manifest)}")
    path
  end

  def relative(path, root)
    path.delete_prefix("#{root}/")
  end

  def payload_header(kind)
    <<~HEADER
      # #{kind}
      # Generated by #{GENERATOR_PATH} from the Ruby plurimath gem. Do not edit.
      # Provenance lives in the sidecar manifest beside this file.
    HEADER
  end

  def manifest_header
    <<~HEADER
      # Sidecar provenance manifest. Generated by #{GENERATOR_PATH}; do not edit.
      # `payload.sha256` covers the whole payload file, header comments included.
    HEADER
  end

  # --- driver --------------------------------------------------------------

  def parse_options(argv)
    options = { gem: nil, out: File.join(REPO_ROOT, "corpus"), allow_dirty: false }
    until argv.empty?
      case (arg = argv.shift)
      when "--gem" then options[:gem] = File.expand_path(argv.shift.to_s)
      when "--out" then options[:out] = File.expand_path(argv.shift.to_s)
      when "--allow-dirty" then options[:allow_dirty] = true
      when "--help", "-h" then options[:help] = true
      else raise Error, "unknown option #{arg.inspect}"
      end
    end
    options
  end

  def usage
    File.readlines(File.join(REPO_ROOT, GENERATOR_PATH))
      .drop(2).take_while { |line| line.start_with?("#") }
      .map { |line| line.sub(/\A# ?/, "") }.join
  end

  def loaded_gem_dir
    loaded = Gem.loaded_specs["plurimath"]
    raise Error, "the plurimath gem is not loaded; set BUNDLE_GEMFILE" unless loaded

    File.expand_path(loaded.full_gem_path)
  end

  def check_checkouts!(gem_dir, requested_gem_dir, out_root, allow_dirty)
    unless git_repository?(gem_dir)
      raise Error, "#{gem_dir} is not a git checkout; the oracle must be one (§7)"
    end

    gem_dirty = dirty_paths(gem_dir)
    repo_dirty = dirty_paths(REPO_ROOT, except: [relative(out_root, REPO_ROOT)])
    dirty = { "gem" => gem_dirty, "generator" => repo_dirty }

    if !allow_dirty && !(gem_dirty.empty? && repo_dirty.empty?)
      raise Error, <<~MESSAGE
        Refusing to generate from a dirty checkout (ARCHITECTURE.md §7).
          gem       #{gem_dir}: #{gem_dirty.empty? ? 'clean' : gem_dirty.join(', ')}
          generator #{REPO_ROOT}: #{repo_dirty.empty? ? 'clean' : repo_dirty.join(', ')}
        Commit or stash, or pass --allow-dirty to produce non-committable output.
      MESSAGE
    end

    if requested_gem_dir && requested_gem_dir != loaded_gem_dir
      raise Error, <<~MESSAGE
        --gem #{requested_gem_dir} is not the checkout bundler loaded
        (#{loaded_gem_dir}). Point BUNDLE_GEMFILE at the same checkout, so the
        recorded provenance describes the code that actually ran.
      MESSAGE
    end

    dirty
  end

  def build_provenance(gem_dir, dirty, allow_dirty)
    gem_spec = Gem.loaded_specs.fetch("plurimath")
    dependencies = dependency_provenance(gem_dir, gem_spec)

    unless dependencies[:external_path_sources].empty?
      message = "path-pinned gems are rejected for canonical generation (§7): " \
                "#{dependencies[:external_path_sources].join(', ')}"
      raise Error, message unless allow_dirty
    end

    warnings = []
    warnings << "generated with --allow-dirty" if allow_dirty
    unless dirty["gem"].empty?
      warnings << "oracle checkout dirty: #{dirty['gem'].join(', ')}"
    end
    unless dirty["generator"].empty?
      warnings << "generator checkout dirty: #{dirty['generator'].join(', ')}"
    end
    unless dependencies[:external_path_sources].empty?
      warnings << "path-pinned gems: #{dependencies[:external_path_sources].join(', ')}"
    end

    {
      "schema" => MANIFEST_SCHEMA,
      "committable" => warnings.empty?,
      "warnings" => warnings,
      "generator" => {
        "path" => GENERATOR_PATH,
        "sha256" => sha256(File.binread(File.join(REPO_ROOT, GENERATOR_PATH))),
        "repository" => checkout_provenance(REPO_ROOT, dirty["generator"]),
      },
      "oracle" => {
        "gem" => "plurimath",
        "version" => gem_spec.version.to_s,
        "kind" => "git-checkout",
      }.merge(checkout_provenance(gem_dir, dirty["gem"])),
      "ruby" => {
        "engine" => RUBY_ENGINE,
        "version" => RUBY_VERSION,
      },
      "xml_engine" => Plurimath.xml_engine.to_s,
      "configuration" => configuration_provenance,
      "dependencies" => dependencies[:provenance],
    }
  end

  def assert_no_deferred_classes!(groups)
    deferred = groups.flat_map { |_name, _description, cases| cases }
      .flat_map { |kase| kase["_classes"].map { |k| [kase["id"], k] } }
      .select { |_id, key| DEFERRED_CLASSES.include?(key) }
    return if deferred.empty?

    raise Error, <<~MESSAGE
      Deferred classes reached the corpus: #{deferred.map { |id, k| "#{id}=>#{k}" }.join(', ')}.
      The deferred-feature classifier matches input text; widen it (§5).
    MESSAGE
  end

  def run(argv)
    options = parse_options(argv)
    if options[:help]
      puts usage
      return 0
    end

    require_ox_engine!
    gem_dir = options[:gem] || loaded_gem_dir
    dirty = check_checkouts!(gem_dir, options[:gem], options[:out],
                             options[:allow_dirty])
    load_model_classes!(gem_dir)

    provenance = build_provenance(gem_dir, dirty, options[:allow_dirty])
    groups, exclusions = build_corpus
    assert_no_deferred_classes!(groups)
    census = build_census(gem_dir)

    out_root = options[:out]
    written = []

    groups.each do |name, description, cases|
      payload = {
        "schema" => CORPUS_SCHEMA,
        "group" => name,
        "description" => description,
        "input_format" => INPUT_FORMAT,
        "targets" => TARGET_FORMATS,
        "cases" => cases.map { |kase| kase.reject { |key, _| key == "_classes" } },
      }
      path = File.join(out_root, "asciimath", "#{name}.yaml")
      bytes = write_payload(path, payload_header("AsciiMath conformance cases: #{name}."), payload)
      written << [path, write_manifest(path, bytes, out_root, provenance)]
    end

    exclusions_payload = {
      "schema" => EXCLUSIONS_SCHEMA,
      "description" => "Cases withheld from every generator because their " \
                       "input matches a deferred construct (ARCHITECTURE.md §5).",
      "features" => DEFERRED_INPUT_PATTERNS.keys.sort,
      "classes" => DEFERRED_CLASSES,
      "excluded" => exclusions.sort_by { |e| e["id"] },
    }
    path = File.join(out_root, "exclusions.yaml")
    bytes = write_payload(path, payload_header("Deferred-feature exclusion manifest."),
                          exclusions_payload)
    written << [path, write_manifest(path, bytes, out_root, provenance)]

    path = File.join(out_root, "census.yaml")
    bytes = write_payload(path, payload_header("Plurimath::Math::Core node census."), census)
    written << [path, write_manifest(path, bytes, out_root, provenance)]

    case_count = groups.sum { |_name, _description, cases| cases.length }
    written.each do |payload_path, manifest_path|
      puts "  #{relative(payload_path, REPO_ROOT)}"
      puts "  #{relative(manifest_path, REPO_ROOT)}"
    end
    puts "#{case_count} cases in #{groups.length} groups, " \
         "#{exclusions.length} excluded, #{census['summary']['total']} classes"
    puts "committable: #{provenance['committable']}"
    provenance["warnings"].each { |warning| puts "  ! #{warning}" }
    0
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit CorpusGenerator.run(ARGV)
  rescue CorpusGenerator::Error => e
    warn "generate-corpus: #{e.message}"
    exit 1
  end
end
