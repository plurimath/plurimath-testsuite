# frozen_string_literal: true

# Generates the AsciiMath conformance corpus from the Ruby plurimath gem,
# which is the oracle.
#
# Usage, from the plurimath-testsuite repository root:
#
#   BUNDLE_GEMFILE=/path/to/plurimath/Gemfile \
#     mise x -- bundle exec ruby scripts/generate-corpus.rb
#
# Options:
#   --gem PATH       gem checkout to treat as the oracle
#                    (default: the checkout bundler resolved `plurimath` from)
#   --out PATH       output root (default: <repo>/corpus)
#   --allow-dirty    generate from a dirty checkout; the output is marked
#                    non-committable in corpus/provenance.yaml
#   --help
#
# Outputs (the payloads, plus one shared provenance file):
#   corpus/asciimath/<group>.yaml   conformance cases, grouped by feature
#   corpus/provenance.yaml          how the payloads above were produced
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
  REJECTIONS_SCHEMA = "plurimath-corpus/rejections/1"
  REJECTIONS_DESCRIPTION =
    "Inputs the gem refuses, so a port can be checked on what it rejects"
  PROVENANCE_SCHEMA = "plurimath-corpus/provenance/2"

  # One provenance document for the whole corpus, not one sidecar per payload.
  # The sidecars repeated 190 identical lines fifteen times; the only facts
  # that ever differed are the three the `payloads` list now carries.
  PROVENANCE_PATH = "provenance.yaml"

  # What a dependency looks like when nothing about it is noteworthy. An
  # entry matching all of these records its version alone (see
  # `direct_runtime_value`).
  DEFAULT_GEM_SOURCE = "https://rubygems.org/"
  DEFAULT_GEM_PLATFORM = "ruby"

  INPUT_FORMAT = "asciimath"
  TARGET_FORMATS = %w[asciimath latex mathml].freeze

  # A `model:` block records a node's *portable semantic state* — what a second
  # implementation has to reproduce — not a dump of every Ruby instance
  # variable. For almost every class the two coincide, so the generic
  # serializer below reads the ivars and that is the model.
  #
  # A class listed here declares its portable state instead. The lambda is
  # given the node and the path of the field being written, and returns the
  # `fields` mapping. This is a positive declaration, not a skip list: a field
  # the projection does not name is out of the model by decision, and an ivar
  # added upstream later stays out until someone decides it belongs — which is
  # exactly what a blacklist of omitted fields could not promise, since it
  # would silently adopt the new field.
  #
  # `Math::Function::Unitsml` holds `@text` and `@unitsml`. Only `@text` is
  # state: the gem builds `@unitsml` as `::Unitsml.parse(text)`, compares two
  # nodes by `text` alone, and clones as `self.class.new(text)`. Serializing
  # `@unitsml` would also drag a second gem's object graph into the corpus —
  # `Unitsml::Formula` reaches `Unitsdb::Prefix`, a units-database record whose
  # lutaml bookkeeping the node only memoizes once something has rendered it,
  # so the field would depend on render order and the generator promises
  # determinism.
  MODEL_PROJECTIONS = {
    "Math::Function::Unitsml" => lambda { |node, path|
      { "text" => serialize_value(node.text, "#{path}.text") }
    },
  }.freeze

  # Seed corpus. Ids are stable and hand-assigned: they are the join key
  # between the payload and every implementation's own suite, so they must not
  # move when a case is inserted.
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
      # "unitsml(zzz)" is deliberately absent: the gem raises
      # Plurimath::Math::ParseError for it, and a case records what the gem
      # rendered, so there is no shape here for an expected error.
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
    ["permissive", "Inputs that look malformed and parse anyway", [
      # The acceptance half of the malformed-input sweep. These were measured
      # as ACCEPTED and then recorded nowhere, so a port could refuse every one
      # of them and still pass this corpus — the rejection cases alone check
      # only that a port refuses enough, never that it accepts enough.
      ["permissive-trailing-caret", "x^"],
      ["permissive-unclosed-paren", "(a"],
      ["permissive-unopened-paren", "a)"],
      ["permissive-closing-run", "))))"],
      # `sqrt(` is deliberately ABSENT. The gem accepts it as AsciiMath input
      # and renders it to asciimath, latex and mathml — but `to_unicodemath`
      # RAISES on the resulting formula, so it cannot carry an expectation for
      # every declared target and this corpus shape has nowhere to put it. It
      # is the one input in the sweep the gem accepts and then cannot fully
      # render; recorded here rather than silently dropped.
      ["permissive-bare-dollar", "$"],
      ["permissive-frac-then-operator", "a/ + b"],
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
  # a committed corpus be regenerated and diffed.
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
      Run `mise x -- bundle install` there first; the provenance records its
      checksum.
    MESSAGE
  end

  # A deliberately small Gemfile.lock reader: enough to record each dependency
  # by source kind, not a general lockfile parser.
  def parse_lockfile(path)
    sources = []
    specs = {}
    current = nil
    bundled_with = nil
    platforms = []
    in_specs = false
    in_bundled = false
    in_platforms = false

    File.readlines(path, chomp: true).each do |line|
      if line.match?(/\A\S/)
        in_specs = false
        in_bundled = line == "BUNDLED WITH"
        # Only PLATFORMS holds platform names. Without this, every indented
        # line of any unrecognised section (DEPENDENCIES, CHECKSUMS, ...) was
        # collected as a platform.
        in_platforms = line == "PLATFORMS"
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
      elsif in_platforms && line.match?(/\A {2}\S/)
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
      .map(&:name).sort.to_h do |name|
      spec = lock[:specs][name]
      raise Error, "#{name} is not resolved in #{path}" unless spec

      [spec["name"], direct_runtime_value(spec)]
    end

    # The per-source gem-name lists are deliberately not recorded: names
    # without versions reproduce nothing, and `lockfile.sha256` already pins
    # every gem at an exact version. `direct_runtime` stays because it carries
    # the versions, which are readable without the lockfile in hand.
    {
      lockfile: {
        "path" => "Gemfile.lock",
        "sha256" => sha256(File.binread(path)),
        "resolved_gems" => lock[:specs].size,
        "platforms" => lock[:platforms],
        "bundler" => lock[:bundled_with],
      },
      direct_runtime: direct,
      external_path_sources: external_path_sources.map { |s| s["remote"] },
    }
  end

  # A dependency resolved plainly from rubygems for the generic Ruby platform
  # records just its version — the other three fields would be the same string
  # repeated once per gem, which is the duplication this format exists to
  # avoid. Anything unusual (a git source, a platform-specific build, a pinned
  # revision) keeps the full mapping, so nothing is lost where it matters.
  def direct_runtime_value(spec)
    source = spec["source"]
    plain = spec["platform"] == DEFAULT_GEM_PLATFORM &&
      source["kind"] == "gem" &&
      source["remote"] == DEFAULT_GEM_SOURCE &&
      source["revision"].nil?
    return spec["version"] if plain

    entry = {
      "version" => spec["version"],
      "platform" => spec["platform"],
      "source_kind" => source["kind"],
      "source" => source["remote"],
    }
    entry["revision"] = source["revision"] if source["revision"]
    entry
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
      Unset PLURIMATH_OGA and re-run. Oga is a parity check only.
    MESSAGE
  end

  # --- serialization -------------------------------------------------------

  def class_key(klass)
    klass.name.to_s.sub("Plurimath::", "")
  end

  def serialize_hash(hash, path)
    result = {}
    hash.each do |key, value|
      name = key.to_s
      if result.key?(name)
        raise Error,
              "duplicate key #{name.inspect} at #{path}"
      end

      result[name] = serialize_value(value, "#{path}.#{name}")
    end
    result.sort.to_h
  end

  # Fails on an unrecognized type rather than falling back to `to_s`: an
  # unserializable field is a corpus gap, and a silent `to_s` would hide it.
  def serialize_value(value, path)
    case value
    when nil, true, false, ::String, ::Integer, ::Float then value
    when ::Symbol, ::Parslet::Slice then value.to_s
    when ::Array
      value.each_with_index.map { |v, i| serialize_value(v, "#{path}[#{i}]") }
    when ::Hash then serialize_hash(value, path)
    when Plurimath::Math::Core then serialize_node(value, path)
    else
      raise Error, "cannot serialize #{value.class} at #{path}"
    end
  end

  # Either the class declares its portable state (MODEL_PROJECTIONS) or every
  # instance variable is that state. Keys are sorted here rather than trusted
  # from either source, so a projection cannot make the payload depend on the
  # order its fields happen to be written in.
  def serialize_node(node, path)
    name = class_key(node.class)
    projection = MODEL_PROJECTIONS[name]
    fields =
      if projection
        project_fields(projection, node, path, name)
      else
        node.variables.to_h do |ivar|
          field = ivar.to_s.delete_prefix("@")
          [field, serialize_value(node.get(ivar), "#{path}.#{field}")]
        end
      end
    { "class" => name, "fields" => fields.sort.to_h }
  end

  def project_fields(projection, node, path, name)
    fields = projection.call(node, path)
    unless fields.is_a?(::Hash) && fields.keys.all?(::String)
      raise Error, "the #{name} projection must return a String-keyed Hash " \
                   "at #{path}, got #{fields.class}"
    end

    fields
  end

  def serialize_tree(node, path)
    case node
    when nil, true, false, ::String, ::Integer, ::Float then node
    when ::Symbol, ::Parslet::Slice then node.to_s
    when ::Array
      node.each_with_index.map { |n, i| serialize_tree(n, "#{path}[#{i}]") }
    when ::Hash then serialize_tree_hash(node, path)
    else
      raise Error, "cannot serialize parse tree node #{node.class} at #{path}"
    end
  end

  # Same shape as `serialize_hash`, and sorted for the same reason: Parslet
  # hands back the keys in the order its rules happened to match, which is an
  # implementation detail of the parslet version in the lockfile. Preserving
  # that order would let a parslet upgrade rewrite every committed parse tree
  # without a single case having changed meaning.
  def serialize_tree_hash(hash, path)
    result = {}
    hash.each do |key, value|
      name = key.to_s
      if result.key?(name)
        raise Error,
              "duplicate key #{name.inspect} at #{path}"
      end

      result[name] = serialize_tree(value, "#{path}.#{name}")
    end
    result.sort.to_h
  end

  # --- corpus --------------------------------------------------------------

  # Candidate malformed inputs, swept rather than assumed. AsciiMath is far
  # more permissive than it looks: `x^`, `(a`, `a)`, `sqrt(`, `))))` and a bare
  # `$` all parse, and even `a/ + b` parses although `a/` does not. Every
  # candidate here is expected to be REFUSED, and `build_rejections` fails the
  # run if the gem accepts one, so this list can never quietly drift into
  # documenting acceptance.
  REJECTION_CANDIDATES = [
    ["frac-trailing", "a/"],
    ["frac-leading", "/b"],
    ["frac-bare", "/"],
    ["frac-trailing-space", "a / "],
    ["backtick-bare", "`"],
    ["right-without-left", "right"],
    ["right-unclosed", "left( x right"],
    # Rejections whose PREPROCESSED text is a different LENGTH from the input.
    # Without at least one of these, every recorded offset is an offset into
    # both texts at once, and a consumer that never maps between them passes
    # anyway. Measured lengths: 4->3, 7->5, 7->5, 12->8.
    ["frac-trailing-after-brace", "{:a/"],
    ["frac-trailing-after-braces", "{:x:}a/"],
    ["frac-trailing-after-parens", "(:x:)y/"],
    ["frac-trailing-after-both", "{:a:}(:b:)c/"],
  ].freeze

  # Parslet reports the *root* rule's failure position, which is 0 for every
  # rejection measured — the root fails at the start whatever went wrong
  # further in. The informative offset is in the deepest cause, so this walks
  # to the leaves and takes the furthest one reached. Recording the root's
  # position instead would fill the corpus with zeros that every
  # implementation would then "match" without checking anything.
  def failure_position(cause)
    children = cause.children || []
    return cause.pos.charpos if children.empty?

    children.map { |child| failure_position(child) }.max
  end

  # The gem's public boundary discards the detail: `Plurimath::Math.parse`
  # rescues everything and re-raises `Math::ParseError` with `cause: nil`. So
  # the category is taken from the public error, and the position from the
  # Parslet layer underneath it, which is the only place it survives.
  def build_rejection(id, input)
    preprocessed = Plurimath::Asciimath::Parser.new(input).text

    category = begin
      Plurimath::Math.parse(input, INPUT_FORMAT.to_sym)
      nil
    rescue Plurimath::Math::ParseError
      "parse_error"
    rescue StandardError => e
      # Anything else is a category the schema has no value for, and inventing
      # one would be worse than stopping: a mislabelled rejection makes every
      # implementation assert the wrong thing. Probed, the gem's other errors
      # come from bad *arguments* rather than bad input, so an input-driven
      # sweep should never reach here.
      raise Error, "#{input.inspect} raised #{e.class}, which is not a " \
                   "category the rejections schema names"
    end

    if category.nil?
      raise Error,
            "the gem ACCEPTED #{input.inspect}; it is not a rejection"
    end

    error = { "category" => category }
    begin
      Plurimath::Asciimath::Parse.new.parse(preprocessed)
    rescue Parslet::ParseFailed => e
      error["index"] = failure_position(e.parse_failure_cause)
    rescue StandardError
      # The failure did not come from the grammar, so no offset exists.
      nil
    end
    {
      "id" => id,
      "input" => input,
      "input_format" => INPUT_FORMAT,
      "preprocessed" => preprocessed,
      "error" => error,
    }
  end

  # A candidate the gem accepts is a defect in the list, not a case to drop:
  # it means the list claims something about the grammar that is not true.
  def build_rejections
    REJECTION_CANDIDATES.map do |id, input|
      build_rejection(id, input)
    rescue Error
      raise
    rescue StandardError => e
      raise Error,
            "rejection #{id} (#{input.inspect}) failed: " \
            "#{e.class}: #{e.message}"
    end
  end

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
    }
  end

  # An input the gem cannot render is a hard failure, not a silent omission:
  # the corpus records what the gem produced, so a case that produces nothing
  # must be noticed and removed from GROUPS by hand, with a reason.
  def build_corpus
    GROUPS.map do |name, description, cases|
      built = cases.map do |id, input|
        build_case(id, input)
      rescue StandardError => e
        raise Error,
              "case #{id} (#{input.inspect}) failed: #{e.class}: #{e.message}"
      end

      [name, description, built]
    end
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
    # Psych writes a nil value as `key: `, with a trailing space. Parsers do not
    # care, but these are committed data files, so every regeneration would
    # reintroduce whitespace a linter or reviewer flags. Stripping it is safe
    # only because the round-trip below verifies it: had it altered anything
    # real — content inside a block scalar, say — the payload would no longer
    # match, and this raises.
    yaml = yaml.gsub(/[ \t]+$/, "")
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

  # `payloads` is a list of [absolute path, written bytes]. Sorted by the
  # recorded path so the document does not depend on the order the payloads
  # happened to be written in.
  def write_provenance(out_root, provenance, payloads)
    document = provenance.merge(
      "payloads" => payloads.map do |payload_path, bytes|
        {
          "path" => relative(payload_path, out_root),
          "sha256" => sha256(bytes),
          "bytes" => bytes.bytesize,
        }
      end.sort_by { |entry| entry["path"] },
    )
    path = File.join(out_root, PROVENANCE_PATH)
    File.binwrite(path, "#{provenance_header}#{dump_yaml(document)}")
    path
  end

  def relative(path, root)
    path.delete_prefix("#{root}/")
  end

  def payload_header(kind)
    <<~HEADER
      # #{kind}
      # Generated by #{GENERATOR_PATH} from the Ruby plurimath gem. Do not edit.
      # Provenance lives in corpus/provenance.yaml.
    HEADER
  end

  def provenance_header
    <<~HEADER
      # Provenance shared by every payload listed below. Generated by
      # #{GENERATOR_PATH}; do not edit.
      # Each `payloads[].sha256` covers that whole payload file, header comments
      # included.
    HEADER
  end

  # --- driver --------------------------------------------------------------

  def parse_options(argv)
    options = { gem: nil, out: File.join(REPO_ROOT, "corpus"),
                allow_dirty: false }
    until argv.empty?
      case (arg = argv.shift)
      when "--gem"
        options[:gem] = File.expand_path(option_value(argv, arg))
      when "--out"
        options[:out] = File.expand_path(option_value(argv, arg))
      when "--allow-dirty" then options[:allow_dirty] = true
      when "--help", "-h" then options[:help] = true
      else raise Error, "unknown option #{arg.inspect}"
      end
    end
    options
  end

  # A value-taking option must actually be given one. `argv.shift` is nil when
  # the flag is last, and `File.expand_path("")` resolves to the working
  # directory without complaint — so `--out` would quietly write the corpus over
  # whatever directory the command happened to run in, and `--gem` would name
  # that directory as the oracle.
  def option_value(argv, option)
    value = argv.shift
    if value.nil? || value.empty?
      raise Error, "missing value for option #{option.inspect}"
    end

    value
  end

  def usage
    File.readlines(File.join(REPO_ROOT, GENERATOR_PATH))
      .drop(2).take_while { |line| line.start_with?("#") }
      .map { |line| line.sub(/\A# ?/, "") }.join
  end

  def loaded_gem_dir
    loaded = Gem.loaded_specs["plurimath"]
    unless loaded
      raise Error,
            "the plurimath gem is not loaded; set BUNDLE_GEMFILE"
    end

    File.expand_path(loaded.full_gem_path)
  end

  def check_checkouts!(gem_dir, requested_gem_dir, out_root, allow_dirty)
    unless git_repository?(gem_dir)
      raise Error, "#{gem_dir} is not a git checkout; the oracle must be " \
                   "one, so the provenance can name the commit it ran"
    end

    gem_dirty = dirty_paths(gem_dir)
    repo_dirty = dirty_paths(REPO_ROOT, except: [relative(out_root, REPO_ROOT)])
    dirty = { "gem" => gem_dirty, "generator" => repo_dirty }

    if !allow_dirty && !(gem_dirty.empty? && repo_dirty.empty?)
      raise Error, <<~MESSAGE
        Refusing to generate from a dirty checkout: the output would record a
        commit that does not describe the code that ran.
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
      message = "path-pinned gems are rejected for canonical generation: " \
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
      pinned = dependencies[:external_path_sources].join(", ")
      warnings << "path-pinned gems: #{pinned}"
    end

    {
      "schema" => PROVENANCE_SCHEMA,
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
      "lockfile" => dependencies[:lockfile],
      "direct_runtime" => dependencies[:direct_runtime],
    }
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

    provenance = build_provenance(gem_dir, dirty, options[:allow_dirty])
    groups = build_corpus

    out_root = options[:out]
    payloads = []

    groups.each do |name, description, cases|
      payload = {
        "schema" => CORPUS_SCHEMA,
        "group" => name,
        "description" => description,
        "input_format" => INPUT_FORMAT,
        "targets" => TARGET_FORMATS,
        "cases" => cases,
      }
      path = File.join(out_root, "asciimath", "#{name}.yaml")
      header = payload_header("AsciiMath conformance cases: #{name}.")
      bytes = write_payload(path, header, payload)
      payloads << [path, bytes]
    end

    rejections = build_rejections
    rejection_payload = {
      "schema" => REJECTIONS_SCHEMA,
      "group" => "rejections",
      "description" => REJECTIONS_DESCRIPTION,
      "input_format" => INPUT_FORMAT,
      "cases" => rejections,
    }
    rejection_path = File.join(out_root, "asciimath", "rejections.yaml")
    rejection_bytes = write_payload(
      rejection_path,
      payload_header("AsciiMath rejection cases."),
      rejection_payload,
    )
    payloads << [rejection_path, rejection_bytes]

    provenance_path = write_provenance(out_root, provenance, payloads)

    case_count = groups.sum { |_name, _description, cases| cases.length }
    payloads.map(&:first).sort.each do |payload_path|
      puts "  #{relative(payload_path, REPO_ROOT)}"
    end
    puts "  #{relative(provenance_path, REPO_ROOT)}"
    puts "#{case_count} cases in #{groups.length} groups, " \
         "#{rejections.length} rejections"
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
