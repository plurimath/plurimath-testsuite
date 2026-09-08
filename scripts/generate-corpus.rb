# frozen_string_literal: true

# Generates the conformance corpus from the Ruby plurimath gem, which is the
# oracle. Every fact that belongs to one input format rather than to the
# corpus as a whole — the parser calls, the target list, the case data — lives
# in a Format descriptor; FORMATS is the list of them, and holds AsciiMath,
# LaTeX and UnicodeMath today.
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
#   corpus/<input_format>/<group>.yaml   conformance cases, by feature group
#   corpus/provenance.yaml               how the payloads above were produced
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

  # The `cases/1` and `cases/2` schema names take their middle segment from
  # the input format, so `case_schema` and `outcome_case_schema` build them per
  # format instead. `rejections/1` names a KIND rather than a format — the
  # payload carries the format in its own `input_format` field — so it is one
  # fixed string.
  REJECTIONS_SCHEMA = "plurimath-corpus/rejections/1"
  # The plain description, carried by a format whose rejection list needs no
  # qualification. A format states its own in `rejection_description`.
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

  # Everything the generator has to know about one input format, in a single
  # object, so that a case list cannot drift away from the parser it was
  # measured against.
  #
  # `name` is both the corpus's `input_format` and the gem's parse type:
  # `Plurimath::Math::VALID_TYPES` is keyed by exactly these names as symbols,
  # which is why `Math.parse` is called with `name.to_sym`, and the `cases/1`
  # and `cases/2` schema names take their middle segment from the same string.
  # `label` is the human spelling, used only in the header comment each payload
  # carries.
  #
  # `targets` names the output formats every case in the format's groups
  # carries an expectation for. Those are `Math::Formula#to_*` names, which are
  # not input-format names — `unicode` is what the gem parses, `unicodemath`
  # what it renders — so the two lists stay separate.
  #
  # `preprocess` and `parse_tree` are the only places a format's parser classes
  # are named. Both take a String. `preprocess` returns the text the
  # `preprocessed` field records, or is nil for a format that has no such pass
  # (see `preprocessed_text`); `parse_tree` returns the grammar's tree, which
  # `serialize_tree` writes.
  #
  # The three case lists are seed data held per format rather than in shared
  # constants: an input is measured against one parser, and a list reachable
  # from every format is a list that will eventually be run against the wrong
  # one.
  #
  # `rejection_description` is the prose the format's rejection payload
  # carries. It is per format rather than shared because a rejection list can
  # hold an entry a reader will misread — one whose name suggests a wider rule
  # than the gem actually applies — and the only place a payload can say so is
  # its own `description`: the `rejections/1` case shape is
  # `additionalProperties: false`, so there is no per-case field for a note.
  Format = Data.define(
    :name, :label, :targets, :preprocess, :parse_tree,
    :groups, :rejection_candidates, :rejection_description, :partial_candidates
  )

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

  # The AsciiMath seed corpus. Ids are stable and hand-assigned: they are the
  # join key between the payload and every implementation's own suite, so they
  # must not move when a case is inserted.
  ASCIIMATH_GROUPS = [
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
    ["fonts", "Font-style commands, which wrap their argument in a FontStyle", [
      ["font-bold", "bb(x)"],
      ["font-blackboard", "bbb(x)"],
      ["font-script", "cc(x)"],
      ["font-typewriter", "tt(x)"],
      ["font-fraktur", "fr(x)"],
      ["font-sans-serif", "sf(x)"],
      ["font-mixed", "bb(A) + cc(B)"],
    ]],
    ["colour", "Colour, whose first argument is a colour name rather than math", [
      ["colour-named", "color(red)(x)"],
      ["colour-in-sum", "color(blue)(x) + y"],
    ]],
    ["left-right", "Explicit left/right fences, which carry their own paren nodes", [
      ["left-right-round", "left( x right)"],
      ["left-right-square", "left[ x right]"],
      ["left-right-around-frac", "left( a/b right)"],
    ]],
    ["mod", "The mod operator, a binary function with no parens of its own", [
      ["mod-simple", "a mod b"],
      ["mod-numeric", "x mod 2"],
      ["mod-in-expression", "(a + b) mod n"],
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

  # Candidate malformed AsciiMath inputs, swept rather than assumed. AsciiMath
  # is far more permissive than it looks: `x^`, `(a`, `a)`, `sqrt(`, `))))` and
  # a bare `$` all parse, and even `a/ + b` parses although `a/` does not. Every
  # candidate here is expected to be REFUSED, and `build_rejections` fails the
  # run if the gem accepts one, so this list can never quietly drift into
  # documenting acceptance.
  ASCIIMATH_REJECTION_CANDIDATES = [
    ["frac-trailing", "a/"],
    ["frac-leading", "/b"],
    ["frac-bare", "/"],
    ["frac-trailing-space", "a / "],
    ["backtick-bare", "`"],
    ["right-without-left", "right"],
    ["right-unclosed", "left( x right"],
    # Measured, not assumed: the gem ACCEPTS `left( x right)` and
    # `left[ x right]` but REFUSES the curly and vertical forms, so these two
    # belong here rather than in the positive corpus. A candidate list that
    # guessed symmetry would have put all four in the wrong place.
    ["left-right-curly", "left{ x right}"],
    ["left-right-vert", "left| x right|"],
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

  # The text a case's `preprocessed` field records: what the format's own
  # preprocessing pass makes of the input before its grammar sees it. A
  # rejection's `index` is an offset into THIS text rather than into `input`,
  # which is why it is recorded at all.
  #
  # A nil `preprocess` says the format has no such pass. There is nowhere to
  # put that fact today — `cases/1`, `cases/2` and `rejections/1` all list
  # `preprocessed` as required — and writing the input back out under a name
  # that claims a pass ran would put a false statement in the corpus. So the
  # run stops here instead, and whoever adds such a format decides how the
  # payload should say it and versions the schema to match.
  def preprocessed_text(format, input)
    unless format.preprocess
      raise Error, "#{format.name} declares no preprocessing pass, and " \
                   "`preprocessed` is required by every payload schema"
    end

    format.preprocess.call(input)
  end

  # The gem's public boundary discards the detail: `Plurimath::Math.parse`
  # rescues everything and re-raises `Math::ParseError` with `cause: nil`. So
  # the category is taken from the public error, and the position from the
  # Parslet layer underneath it, which is the only place it survives.
  def build_rejection(format, id, input)
    preprocessed = preprocessed_text(format, input)

    category = begin
      Plurimath::Math.parse(input, format.name.to_sym)
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
      format.parse_tree.call(preprocessed)
    rescue Parslet::ParseFailed => e
      error["index"] = failure_position(e.parse_failure_cause)
    rescue StandardError
      # The failure did not come from the grammar, so no offset exists.
      nil
    end
    {
      "id" => id,
      "input" => input,
      "input_format" => format.name,
      "preprocessed" => preprocessed,
      "error" => error,
    }
  end

  # A candidate the gem accepts is a defect in the list, not a case to drop:
  # it means the list claims something about the grammar that is not true.
  def build_rejections(format)
    format.rejection_candidates.map do |id, input|
      build_rejection(format, id, input)
    rescue Error
      raise
    rescue StandardError => e
      raise Error,
            "rejection #{id} (#{input.inspect}) failed: " \
            "#{e.class}: #{e.message}"
    end
  end

  # --- partially renderable cases (cases/2) --------------------------------

  # Inputs the gem ACCEPTS but renders to only SOME targets. `cases/1` cannot
  # hold one: it demands a rendered string from every case for every target,
  # so these were simply left out of the corpus — and an input left out is an
  # input a port may refuse while still passing every case here. They get the
  # `cases/2` shape, where each target carries an outcome.
  #
  # The group name and description are the same for every format: the payloads
  # sit in per-format directories, so the names cannot collide.
  PARTIAL_GROUP = "partial-render"
  PARTIAL_DESCRIPTION =
    "Inputs the gem accepts but renders to only some targets"

  # Measured, not assumed. `sqrt(` parses (`Math::Formula`), renders to
  # asciimath, latex and mathml, and raises `Math::ParseError` from
  # `to_unicodemath`. `build_partial_cases` fails the run if a candidate here
  # renders to EVERY target — that one belongs in a `cases/1` group, and a
  # list that quietly kept it would be claiming a refusal that stopped
  # happening.
  ASCIIMATH_PARTIAL_CANDIDATES = [
    ["partial-sqrt-unclosed", "sqrt("],
  ].freeze

  # AsciiMath, the first input format the corpus covered. Assembled here rather
  # than beside `Format` because it names the three case lists above.
  #
  # `Asciimath::Parser` preprocesses in its constructor — it rewrites `{:`,
  # `:}`, `(:`, `:)` and both of `|:` and `:|` to single characters — and
  # `#text` is that rewritten string. `Asciimath::Parse` is the Parslet grammar
  # the gem then runs over it, and is where a rejection's offset comes from.
  ASCIIMATH = Format.new(
    name: "asciimath",
    label: "AsciiMath",
    targets: %w[asciimath latex mathml unicodemath].freeze,
    preprocess: ->(input) { Plurimath::Asciimath::Parser.new(input).text },
    parse_tree: ->(text) { Plurimath::Asciimath::Parse.new.parse(text) },
    groups: ASCIIMATH_GROUPS,
    rejection_candidates: ASCIIMATH_REJECTION_CANDIDATES,
    rejection_description: REJECTIONS_DESCRIPTION,
    partial_candidates: ASCIIMATH_PARTIAL_CANDIDATES,
  )

  # The LaTeX seed corpus, grown a slice at a time: four groups first, then the
  # fourteen below them, then the rejection list above and the fourteen
  # placeholder cases an earlier slice had wrongly excluded. A partially
  # renderable payload is still outstanding, and `write_format` writes no
  # payload for a kind whose candidate list is still empty.
  #
  # Ids carry a `latex-` prefix while the AsciiMath ids carry none. That is not
  # decoration: this repository enforces id uniqueness WITHIN a group, while at
  # least one consumer collects every payload's cases into a single map keyed by
  # id and raises on a repeat. Two formats sharing an id therefore PASSES here
  # and breaks there — a failure this repository's own suite cannot see.
  # Prefixing one format's ids makes the collision impossible, and the AsciiMath
  # ids are already published, so the prefix goes on the newer format.
  #
  # The consumer measured was the TypeScript port. Its file is deliberately not
  # named: that path lives in another repository, and naming it here sends a
  # reader looking for it in this one.
  #
  # Group NAMES do repeat across formats, and may: a group lives in the
  # directory named after its input format, so `asciimath/numbers` and
  # `latex/numbers` are distinct payloads that no consumer can confuse.
  #
  # A candidate is admitted when the gem renders it to EVERY target. Whether a
  # rendering happens to be the parsing wrapper does NOT bear on admission, and
  # an earlier slice was wrong to think it did.
  #
  # `Math::Symbols::Symbol#parsing_wrapper` is the gem's placeholder for a
  # construct it has no name for in the target notation, in two spellings:
  # `"P{name}"` for asciimath and unicodemath, `\text{P[name]}` for latex. The
  # corpus records what the gem OUTPUTS, and the gem genuinely outputs these,
  # so a port that renders something better than the placeholder diverges from
  # the oracle. Excluding them therefore hid real behaviour rather than
  # protecting anyone from it: the rule dropped fourteen inputs, and they are
  # back below, in the groups they belong to.
  #
  # What a reader still must not do is mistake such a case for coverage of the
  # construct — it is coverage of the gem's GAP. That distinction cannot live
  # in this file, which no consumer of the corpus reads, so every group holding
  # one says it in its own payload description, through PLACEHOLDER_NOTE.
  #
  # An input the gem cannot render to EVERY target is still excluded from these
  # groups: `cases/1` demands a rendered string per target and has no shape for
  # a refusal. Such an input belongs in `partial_candidates` instead.
  PLACEHOLDER_NOTE =
    " Some cases here record a deferred-construct placeholder rather than a " \
    "rendering: where the gem has no name for a construct in a target " \
    "notation, `Math::Symbols::Symbol#parsing_wrapper` emits `\"P{name}\"` " \
    "-- the quotes are part of the emitted string -- for " \
    "asciimath and unicodemath, or `\\text{P[name]}` for latex. The corpus " \
    "records what the gem produced, so the placeholder IS the expectation " \
    "and a port that renders something better fails the case."

  LATEX_GROUPS = [
    ["numbers", "Number literals: decimal, braced, signed and exponentiated", [
      ["latex-number-integer", "1"],
      ["latex-number-decimal", "3.14"],
      ["latex-number-decimal-comma", "1{,}5"],
      ["latex-number-negative", "-42"],
      ["latex-number-braced-exponent", "2^{10}"],
    ]],
    ["symbols",
     "Backslash-named symbols: Greek letters and constants." +
     PLACEHOLDER_NOTE, [
      ["latex-symbol-greek-alpha", "\\alpha"],
      ["latex-symbol-infinity", "\\infty"],
      ["latex-symbol-greek-pi", "\\pi"],
      # This one renders to every target, and its asciimath rendering is the
      # parsing wrapper: `"P{emptyset}"`, while latex says `\varnothing` and
      # mathml and unicodemath name the symbol properly. It is why this group
      # carries the note. The UnicodeMath `symbols` group reaches the SAME gap
      # from the other side, through the literal `∅`.
      ["latex-symbol-empty-set", "\\emptyset"],
    ]],
    ["operators", "Binary operators, bare and backslash-named", [
      ["latex-operator-plus", "a + b"],
      ["latex-operator-times", "a \\times b"],
      ["latex-operator-leq", "a \\le b"],
      ["latex-operator-equiv", "a \\equiv b"],
      ["latex-operator-plus-minus", "a \\pm b"],
    ]],
    ["fences", "Fenced groups: bare, escaped and backslash-named delimiters", [
      ["latex-fence-round", "(a)"],
      ["latex-fence-square", "[a]"],
      ["latex-fence-curly-escaped", "\\{a\\}"],
      ["latex-fence-angle", "\\langle a \\rangle"],
      ["latex-fence-ceiling", "\\lceil a \\rceil"],
    ]],
    ["frac", "Fractions, whose numerator and denominator are braced groups", [
      ["latex-frac-simple", "\\frac{1}{2}"],
      ["latex-frac-nested", "\\frac{\\frac{1}{2}}{3}"],
      ["latex-frac-sum-numerator", "\\frac{a+b}{c}"],
      ["latex-frac-sum-denominator", "\\frac{x}{y+z}"],
      ["latex-frac-sum-of-fracs", "\\frac{1}{2} + \\frac{3}{4}"],
      ["latex-frac-root-denominator", "\\frac{1}{\\sqrt{2}}"],
      # `\dfrac` and `\tfrac` are deliberately absent: the gem rejects both.
      # They belong in a rejection payload, which LaTeX does not have yet.
    ]],
    ["powers", "Superscripts and subscripts, braced and bare", [
      ["latex-power-square", "x^2"],
      ["latex-power-nested", "x^{y^z}"],
      ["latex-power-braced-exponent", "x^{n+1}"],
      ["latex-power-exponential", "e^x"],
      ["latex-subscript-letter", "x_i"],
      ["latex-subscript-braced", "a_{n+1}"],
      ["latex-subscript-and-power", "x_i^2"],
      # `{}_a^b x`, the prescript spelling, is deliberately absent: the gem
      # rejects it.
    ]],
    ["roots", "Square roots, and the bracketed index of an nth root", [
      ["latex-root-sqrt-number", "\\sqrt{2}"],
      ["latex-root-sqrt-sum", "\\sqrt{x+1}"],
      ["latex-root-sqrt-pythagoras", "\\sqrt{a^2+b^2}"],
      ["latex-root-sqrt-frac", "\\sqrt{\\frac{1}{2}}"],
      ["latex-root-cube", "\\sqrt[3]{8}"],
      ["latex-root-nth-symbolic", "\\sqrt[n]{x}"],
    ]],
    ["unary-functions", "Named functions, applied bare and to a fenced group", [
      ["latex-unary-sin-bare", "\\sin x"],
      ["latex-unary-sin-fenced", "\\sin(x)"],
      ["latex-unary-cos-product", "\\cos(2x)"],
      ["latex-unary-log-bare", "\\log x"],
      ["latex-unary-ln-bare", "\\ln x"],
      ["latex-unary-lim-bare", "\\lim x"],
      ["latex-unary-det", "\\det A"],
      ["latex-unary-max", "\\max A"],
      ["latex-unary-gcd-fenced", "\\gcd(a,b)"],
    ]],
    ["quoted-text", "Literal text, whose braces hold characters, not math", [
      ["latex-text-command", "\\text{hello}"],
      ["latex-text-spaced", "\\text{hello world}"],
      ["latex-text-mbox", "\\mbox{hi}"],
      ["latex-text-mbox-spaced", "\\mbox{a b}"],
      # `\textrm{abc}` is NOT here: measured, it parses as `fonts: "textrm"`,
      # not `text:`, and renders `\mathrm{a b c}` rather than `\text{...}`.
      # It is a font command wearing a text-looking name, so it lives in
      # `fonts` where a reader will expect its behaviour.
    ]],
    ["nary",
     "n-ary operators and limit-bearing functions, bounded and bare." +
     PLACEHOLDER_NOTE, [
      ["latex-nary-sum-bounded", "\\sum_{i=1}^{n} i"],
      ["latex-nary-sum-of-squares", "\\sum_{i=1}^{n} i^2"],
      ["latex-nary-sum-bare", "\\sum x"],
      ["latex-nary-int-bounded", "\\int_0^1 x"],
      ["latex-nary-int-definite", "\\int_a^b f(x) dx"],
      ["latex-nary-prod-subscript", "\\prod_{k} k"],
      ["latex-nary-prod-bounded", "\\prod_{i=1}^{n} i"],
      ["latex-nary-oint-subscript", "\\oint_C f"],
      ["latex-nary-lim-to-infinity", "\\lim_{x \\to \\infty} f(x)"],
      # The five below render to every target. Their asciimath renderings are
      # the parsing wrapper — `"P{duni}"`, `"P{dint}"`, `"P{coprod}"`,
      # `"P{iint}"`, `"P{bigoplus}"` — while latex, mathml and unicodemath all
      # name the operator properly. Measured, and recorded as measured.
      ["latex-nary-bigcup-subscript", "\\bigcup_i A_i"],
      ["latex-nary-bigcap-subscript", "\\bigcap_i A_i"],
      ["latex-nary-coprod-subscript", "\\coprod_i A_i"],
      ["latex-nary-iint-bare", "\\iint f"],
      ["latex-nary-bigoplus-subscript", "\\bigoplus_i A_i"],
    ]],
    ["matrices", "Matrix environments, one per delimiter pair", [
      ["latex-matrix-plain", "\\begin{matrix} a & b \\end{matrix}"],
      ["latex-matrix-parens", "\\begin{pmatrix} a \\\\ b \\end{pmatrix}"],
      ["latex-matrix-brackets", "\\begin{bmatrix} a \\end{bmatrix}"],
      ["latex-matrix-bars", "\\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix}"],
      ["latex-matrix-braces", "\\begin{Bmatrix} a \\end{Bmatrix}"],
      ["latex-matrix-array", "\\begin{array}{cc} a & b \\end{array}"],
    ]],
    ["fonts", "Font-style commands, which wrap their argument in a FontStyle", [
      ["latex-font-blackboard", "\\mathbb{R}"],
      ["latex-font-bold", "\\mathbf{x}"],
      # Parses as `fonts: "textrm"` and renders `\mathrm{a b c}`; the name
      # looks like a text command but the gem treats it as a font one.
      ["latex-font-roman-text", "\\textrm{abc}"],
      ["latex-font-script", "\\mathcal{L}"],
      ["latex-font-fraktur", "\\mathfrak{g}"],
      ["latex-font-sans-serif", "\\mathsf{A}"],
      ["latex-font-typewriter", "\\mathtt{z}"],
      ["latex-font-roman", "\\mathrm{d}"],
      ["latex-font-italic", "\\mathit{x}"],
      ["latex-font-mixed", "\\mathbf{A} + \\mathbf{B}"],
    ]],
    ["colour", "Colour, whose first argument is a colour name, not math", [
      ["latex-colour-named", "\\color{red} x"],
      ["latex-colour-in-sum", "\\color{blue} y + z"],
      ["latex-colour-over-frac", "\\color{red} \\frac{1}{2}"],
      # `\textcolor{blue}{y}` is deliberately absent: the gem rejects it, while
      # the `\color` spelling above is accepted.
    ]],
    ["left-right", "\\left and \\right fences, which size their delimiters", [
      ["latex-left-right-round", "\\left( a \\right)"],
      ["latex-left-right-square", "\\left[ x \\right]"],
      ["latex-left-right-curly", "\\left\\{ a \\right\\}"],
      ["latex-left-right-bar", "\\left| x \\right|"],
      ["latex-left-right-round-sum", "\\left( a + b \\right)"],
      ["latex-left-right-around-frac", "\\left( \\frac{a}{b} \\right)"],
    ]],
    ["mod", "Modulo, in its \\mod, \\bmod and \\pmod spellings", [
      ["latex-mod-infix", "a \\mod b"],
      ["latex-mod-bmod", "a \\bmod b"],
      ["latex-mod-pmod", "a \\pmod{b}"],
      ["latex-mod-numeric", "x \\mod 2"],
      ["latex-mod-fenced-left", "(a+b) \\mod n"],
    ]],
    ["whitespace",
     "Spacing commands, which survive the space-deleting pass." +
     PLACEHOLDER_NOTE, [
      ["latex-whitespace-quad", "a \\quad b"],
      ["latex-whitespace-two-quads", "a \\quad b \\quad c"],
      # NOT a thin space, whatever the LaTeX spelling suggests: measured, `\,`
      # parses as `symbols: ","` and renders `a , b`. Recorded under a name
      # that says what the gem does, so a port implementing thin-space
      # semantics is not misled by the id. `\quad` above really is spacing —
      # it parses as `symbols: "quad"` — which is why the two sit together.
      ["latex-comma-from-thin-space", "a \\, b"],
      ["latex-whitespace-medium", "a \\: b"],
      # `a \hspace{1em} b` is deliberately absent: the gem rejects it.
      #
      # The two below were excluded under the repealed rule, and both really do
      # match it: asciimath renders them `a "P{\;}" b` and `a "P{qquad}" b`.
      # The rule, not the reading, was what was wrong — that is what the gem
      # produced, so that is what the corpus records.
      ["latex-whitespace-thick", "a \\; b"],
      ["latex-whitespace-qquad", "a \\qquad b"],
    ]],
    ["accents",
     "Accents, which decorate their argument, not fence it." +
     PLACEHOLDER_NOTE, [
      ["latex-accent-hat", "\\hat{a}"],
      ["latex-accent-hat-multi", "\\hat{ab}"],
      ["latex-accent-vec", "\\vec{v}"],
      ["latex-accent-vec-multi", "\\vec{AB}"],
      ["latex-accent-bar", "\\bar{x}"],
      ["latex-accent-dot", "\\dot{x}"],
      ["latex-accent-ddot", "\\ddot{y}"],
      ["latex-accent-tilde", "\\tilde{n}"],
      # Accents the gem parses as bare symbols rather than as decorations: it
      # renders each to asciimath as the parsing wrapper applied to the accent
      # name, with the argument left beside it — `"P{acute}" a`, not an accent
      # over `a`. `\mathring` wraps as `"P{ring}"`, which is the gem's own name
      # for the symbol and not a typo for the command.
      ["latex-accent-acute", "\\acute{a}"],
      ["latex-accent-grave", "\\grave{a}"],
      ["latex-accent-check", "\\check{a}"],
      ["latex-accent-breve", "\\breve{a}"],
      ["latex-accent-mathring", "\\mathring{a}"],
    ]],
    ["over-under",
     "Lines and braces drawn above or below an argument." +
     PLACEHOLDER_NOTE, [
      ["latex-over-under-overline", "\\overline{ab}"],
      ["latex-over-under-overline-sum", "\\overline{a+b}"],
      ["latex-over-under-overline-nested", "\\overline{\\overline{a}}"],
      ["latex-over-under-underbrace", "\\underbrace{ab}"],
      ["latex-over-under-underbrace-sum", "\\underbrace{a+b}"],
      ["latex-over-under-underbrace-labelled", "\\underbrace{x}_{y}"],
      ["latex-over-under-overset", "\\overset{x}{y}"],
      ["latex-over-under-underset", "\\underset{x}{y}"],
      ["latex-over-under-stackrel", "\\stackrel{x}{y}"],
      # `\overbrace{ab}` is absent because it is UNREACHABLE, not because it
      # was skipped. `Latex::Constants::SYMBOLS` classifies `overbrace:
      # :underover`, but the grammar's underover alternative reads
      # `Constants::UNDEROVER_CLASSES`, which holds only `bmod`, `pmod` and
      # `mod`. No rule reaches the entry, so the gem rejects `\overbrace{ab}`
      # — measured, and nothing here works around it.
      #
      # The two below are the over-under counterparts of the accents above:
      # the gem parses each as a bare symbol, so asciimath gets the parsing
      # wrapper with the argument beside it rather than a line or a brace over
      # it. `\overparen` wraps as `"P{wideparen}"` — again the gem's name for
      # the symbol, not the command's.
      ["latex-over-under-underline", "\\underline{ab}"],
      ["latex-over-under-overparen", "\\overparen{ab}"],
    ]],
  ].freeze

  # Candidate malformed LaTeX inputs, swept rather than assumed. Every entry
  # is expected to be REFUSED, and `build_rejections` fails the run if the gem
  # accepts one, so this list cannot quietly drift into documenting acceptance.
  #
  # Five candidates were probed and are NOT here, each for a measured reason:
  #
  #   `\left( x`, `\sqrt[` and `\begin{array}{zz} a \end{array}` are ACCEPTED.
  #   The gem parses all three into a `Math::Formula`; what fails is RENDERING.
  #   `\left( x` and the bad array spec raise from every target, `\sqrt[`
  #   raises from asciimath, latex and unicodemath and renders to mathml. That
  #   is the `cases/2` shape, not this one — they are candidates for LaTeX's
  #   `partial_candidates`, which is still empty, and not rejections.
  #
  #   The empty input `""` IS refused, but `rejections/1` gives `input` a
  #   `minLength` of 1 on purpose: "an implementation has to be given something
  #   to refuse". `"   "` below is the recordable neighbour — it is refused
  #   too, and its `preprocessed` is `""`, because the space-deleting pass
  #   empties it.
  #
  #   `&#x110000;` IS refused, and cannot be recorded here at all: the refusal
  #   happens INSIDE the preprocessing pass, so there is no `preprocessed` text
  #   to write and the field is required. `Latex::Parser#pre_processing` round
  #   trips the input through HTMLEntities, and that raises `RangeError:
  #   1114112 out of char range` before the grammar is ever reached. Writing
  #   `input` into `preprocessed` would state that a pass ran which did not —
  #   the same false statement `preprocessed_text` refuses to make for a format
  #   with no pass at all. Recording it needs a schema that can say "refused
  #   before preprocessing", which is a version bump, not a case.
  LATEX_REJECTION_CANDIDATES = [
    ["latex-unclosed-brace", "\\frac{1"],
    ["latex-stray-close-brace", "x}"],
    ["latex-unknown-command", "\\nosuchcommandhere"],
    ["latex-frac-no-args", "\\frac"],
    ["latex-frac-one-arg", "\\frac{1}"],
    ["latex-right-without-left", "x \\right)"],
    ["latex-begin-without-end", "\\begin{matrix} a"],
    ["latex-end-without-begin", "a \\end{matrix}"],
    ["latex-whitespace-only", "   "],
    ["latex-lone-backslash", "\\"],
    ["latex-unclosed-text", "\\text{abc"],
    ["latex-nested-unclosed", "\\frac{\\frac{1}{2}"],
    ["latex-command-bad-chars", "\\fr@c{1}{2}"],
    # `~` is ordinary LaTeX for a non-breaking space, so this one is a
    # divergence candidate rather than an obvious refusal. It is recorded
    # because the gem refuses it today; if that ever changes, the change is
    # visible here rather than silent.
    ["latex-tilde", "a~b"],
  ].freeze

  # LaTeX states its own rejection prose because two of the things a reader
  # will want to know about this list are about inputs that are NOT in it. See
  # the exclusions above `LATEX_REJECTION_CANDIDATES`; this is the part of them
  # a consumer of the corpus can see.
  LATEX_REJECTIONS_DESCRIPTION =
    "Inputs the gem refuses, so a port can be checked on what it rejects. " \
    "Two notes, because the obvious reading of this list is wrong in both " \
    "places. `latex-tilde` is a divergence candidate rather than a plain " \
    "refusal: `~` is ordinary LaTeX for a non-breaking space, and the gem " \
    "refuses it anyway. And two further refusals measured against this " \
    "oracle are deliberately absent, because this schema cannot express " \
    "them — the empty input, which `input` forbids by minLength, and " \
    "`&#x110000;`, a WELL-FORMED hex entity above the Unicode maximum, whose " \
    "refusal comes from the HTMLEntities round trip inside the preprocessing " \
    "pass itself, leaving no `preprocessed` text to record. Malformed " \
    "entities are the opposite case and are ACCEPTED, falling through as " \
    "literal characters: `&nosuchentity;`, `&#xZZ;`, `&;` and `&pi` all parse."

  # LaTeX, the second input format.
  #
  # `Latex::Parser` preprocesses in its constructor exactly as its AsciiMath
  # sibling does — `#initialize` assigns `@text = pre_processing(text)`, and
  # `attr_accessor :text` is that rewritten string. The pass round-trips the
  # input through HTMLEntities and then deletes every space not preceded by a
  # backslash, so `a + b` reaches the grammar as `a+b` and the two texts differ
  # in length, which is what a rejection's `index` is an offset into.
  # `Latex::Parse` is the Parslet grammar the gem then runs over it.
  LATEX = Format.new(
    name: "latex",
    label: "LaTeX",
    targets: %w[asciimath latex mathml unicodemath].freeze,
    preprocess: ->(input) { Plurimath::Latex::Parser.new(input).text },
    parse_tree: ->(text) { Plurimath::Latex::Parse.new.parse(text) },
    groups: LATEX_GROUPS,
    rejection_candidates: LATEX_REJECTION_CANDIDATES,
    rejection_description: LATEX_REJECTIONS_DESCRIPTION,
    partial_candidates: [].freeze,
  )

  # The UnicodeMath seed corpus, the third input format, and the first slice of
  # it: four groups, the same four LaTeX opened with, so the two formats can be
  # read side by side.
  #
  # The name is `unicode`, not `unicodemath`. That is the gem's PARSE type —
  # `Math::VALID_TYPES` keys `Plurimath::UnicodeMath` under `:unicode`, and
  # `LOCALIZED_PARSE_TYPES` spells it the same way — while `unicodemath` is the
  # RENDER target, the `Formula#to_unicodemath` name every format's `targets`
  # already lists. So this format both parses `unicode` and renders back to
  # `unicodemath`, and the corpus's `input_format` and `targets` fields
  # deliberately disagree in spelling. Conflating them would make
  # `Math.parse(input, :unicodemath)` the call, which raises `InvalidTypeError`.
  #
  # Ids carry a `unicode-` prefix for the reason the LaTeX ids carry `latex-`:
  # uniqueness is enforced here only WITHIN a group, while a consumer keys every
  # payload's cases into one map and raises on a repeat. The prefix was checked
  # against all 244 ids the corpus held before this slice; none began with it.
  #
  # UnicodeMath's inputs are the notation itself — literal `α`, `×`, `⌈`, not a
  # backslash name — so the groups below are the same features written in
  # characters. That difference is the whole reason this format needs its own
  # cases rather than a translation of LaTeX's: the gem reaches a DIFFERENT
  # symbol table on the way in, and two notations that agree on a construct can
  # still disagree on which target can name it again on the way out.
  #
  # Which is exactly what `symbols` and `operators` record. `∅` renders to
  # latex, mathml and unicodemath properly and to asciimath as `"P{emptyset}"`;
  # `a∓b` does the same through `"P{mp}"`. Both are `parsing_wrapper` output —
  # the gem has no asciimath name for the construct — and both are admitted,
  # because the corpus records what the gem produced and a port that renders
  # something better diverges from the oracle. Their two groups say so in their
  # own descriptions, through PLACEHOLDER_NOTE, so that a reader of the payload
  # does not mistake the case for coverage of the construct: it is coverage of
  # the gem's gap.
  #
  # `∓` is paired with `±` on purpose. They are adjacent operators of the same
  # shape, one of which asciimath can name and one of which it cannot, and a
  # port that assumes the pair behaves alike fails on exactly one of them.
  #
  # `1,5` is a real comma decimal here rather than a sequence: measured, it
  # parses as `decimal_number` with `decimal: ","`, one `Math::Number` node —
  # so the id says decimal-comma truthfully. `-42` is the opposite and the id
  # is loose in the way LaTeX's already is: it parses as TWO nodes, a
  # `Symbols::Minus` and a `Number`, not a signed literal.
  #
  # Rejections and partially renderable inputs are not in this slice.
  # `write_format` writes no payload for a kind whose candidate list is empty,
  # so their absence claims only that none are recorded yet. One partial
  # candidate is already measured and waiting for that slice: `⎣2.5⎦` parses
  # and then fails to render to every one of the four targets.
  UNICODEMATH_GROUPS = [
    ["numbers", "Number literals: integer, decimal, comma-decimal, signed " \
                "and exponentiated", [
      ["unicode-number-integer", "1"],
      ["unicode-number-decimal", "3.14"],
      ["unicode-number-decimal-comma", "1,5"],
      ["unicode-number-negative", "-42"],
      ["unicode-number-exponent", "2^10"],
    ]],
    ["symbols",
     "Literal Unicode symbols: Greek letters and constants." +
     PLACEHOLDER_NOTE, [
      ["unicode-symbol-greek-alpha", "α"],
      ["unicode-symbol-greek-pi", "π"],
      ["unicode-symbol-infinity", "∞"],
      # asciimath renders this one as `"P{emptyset}"`. Measured, and recorded
      # as measured.
      ["unicode-symbol-empty-set", "∅"],
    ]],
    ["operators",
     "Binary operators written as the literal Unicode character." +
     PLACEHOLDER_NOTE, [
      ["unicode-operator-plus", "a+b"],
      ["unicode-operator-times", "a×b"],
      ["unicode-operator-leq", "a≤b"],
      ["unicode-operator-equiv", "a≡b"],
      ["unicode-operator-plus-minus", "a±b"],
      # asciimath renders this one as `a "P{mp}" b`, while its `±` sibling
      # above renders as `a pm b`.
      ["unicode-operator-minus-plus", "a∓b"],
    ]],
    ["fences", "Fenced groups: ASCII, angle and ceiling delimiters", [
      ["unicode-fence-round", "(a)"],
      ["unicode-fence-square", "[a]"],
      ["unicode-fence-curly", "{a}"],
      ["unicode-fence-angle", "⟨a⟩"],
      ["unicode-fence-ceiling", "⌈a⌉"],
    ]],
  ].freeze

  # UnicodeMath, the third input format.
  #
  # `UnicodeMath::Parser` preprocesses in its constructor as both its siblings
  # do, and further than either: it splits the input on `#` to lift out a
  # labelled-row id, encodes the result through HTMLEntities as HEXADECIMAL
  # entities, then puts `&`, `"` and `\` back, strips a `⫷…⫸` span, rewrites
  # `\uXXXX` escapes to entities, and strips the ends. So the whole point of
  # this format — its literal characters — reaches the grammar as `&#x3b1;`
  # rather than as `α`, which is what each case's `preprocessed` field shows
  # and what a rejection's `index` would be an offset into.
  #
  # `#text` is that rewritten string and `UnicodeMath::Parse` is the Parslet
  # grammar run over it. One caveat for whoever adds the labelled-row cases:
  # `Parser#parse` post-processes the grammar's tree when the input carried a
  # `#`, so for those inputs alone the tree recorded here is not the tree the
  # parser goes on to transform. No case in this slice contains a `#`.
  UNICODEMATH = Format.new(
    name: "unicode",
    label: "UnicodeMath",
    targets: %w[asciimath latex mathml unicodemath].freeze,
    preprocess: ->(input) { Plurimath::UnicodeMath::Parser.new(input).text },
    parse_tree: ->(text) { Plurimath::UnicodeMath::Parse.new.parse(text) },
    groups: UNICODEMATH_GROUPS,
    rejection_candidates: [].freeze,
    rejection_description: REJECTIONS_DESCRIPTION,
    partial_candidates: [].freeze,
  )

  # Every input format the corpus is generated for, in the order they are
  # written. A further format is one more `Format` and one more entry here.
  FORMATS = [ASCIIMATH, LATEX, UNICODEMATH].freeze

  # One target's outcome. The category comes from the gem's PUBLIC boundary,
  # which is the only thing a port can be asked to reproduce: `Formula#to_*`
  # funnels render failures through `wrap_render_error`, which re-raises
  # `Math::ParseError` — the underlying error survives as `#cause` alone, so
  # naming it here would name a Ruby detail no port has. Anything that is not
  # that public error is a category the schema has no value for, and inventing
  # one is worse than stopping: a mislabelled outcome makes every port assert
  # the wrong thing.
  def render_outcome(formula, target, input)
    { "output" => formula.public_send("to_#{target}") }
  rescue Plurimath::Math::ParseError
    { "error" => { "category" => "parse_error" } }
  rescue StandardError => e
    raise Error,
          "rendering #{input.inspect} to #{target} raised #{e.class}, " \
          "which is not a category the cases/2 schema names"
  end

  def build_partial_case(format, id, input)
    formula = Plurimath::Math.parse(input, format.name.to_sym)
    preprocessed = preprocessed_text(format, input)
    tree = format.parse_tree.call(preprocessed)
    outcomes = format.targets.to_h do |target|
      [target, render_outcome(formula, target, input)]
    end

    if outcomes.each_value.none? { |outcome| outcome.key?("error") }
      raise Error,
            "the gem rendered #{input.inspect} to every target; it is not a " \
            "partially renderable case and belongs in a cases/1 group"
    end

    {
      "id" => id,
      "input" => input,
      "input_format" => format.name,
      "preprocessed" => preprocessed,
      "expected" => outcomes,
      "parse_tree" => serialize_tree(tree, id),
      "model" => serialize_node(formula, id),
    }
  end

  def build_partial_cases(format)
    format.partial_candidates.map do |id, input|
      build_partial_case(format, id, input)
    rescue Error
      raise
    rescue StandardError => e
      raise Error,
            "partial case #{id} (#{input.inspect}) failed: " \
            "#{e.class}: #{e.message}"
    end
  end

  def build_case(format, id, input)
    formula = Plurimath::Math.parse(input, format.name.to_sym)
    preprocessed = preprocessed_text(format, input)
    tree = format.parse_tree.call(preprocessed)
    # Every target the format declares, in the order it declares them. The
    # payload states that list once for the whole group, and
    # scripts/validate.rb reconciles it against each case's `expected` keys in
    # both directions, so a target rendered here but not declared — or
    # declared but not rendered — fails validation rather than passing quietly.
    expected = format.targets.to_h do |target|
      [target, formula.public_send("to_#{target}")]
    end

    {
      "id" => id,
      "input" => input,
      "input_format" => format.name,
      "preprocessed" => preprocessed,
      "expected" => expected,
      "parse_tree" => serialize_tree(tree, id),
      "model" => serialize_node(formula, id),
    }
  end

  # An input the gem cannot render is a hard failure, not a silent omission:
  # the corpus records what the gem produced, so a case that produces nothing
  # must be noticed and removed from the format's groups by hand, with a
  # reason.
  def build_corpus(format)
    format.groups.map do |name, description, cases|
      built = cases.map do |id, input|
        build_case(format, id, input)
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

  # The counterpart to `write_payload` for a payload this run does not produce.
  #
  # `cases` is `minItems: 1` in all three schemas, so a format with no rejection
  # or partially-renderable candidates cannot be given an empty payload — it
  # would be a file no schema accepts. Skipping the write alone is not enough
  # either: the generator otherwise only ever writes, so a payload dropped
  # between runs would survive on disk, stay in the corpus, and no longer appear
  # in `provenance.yaml`'s `payloads` list. Removing it keeps the directory and
  # the provenance describing the same set of files.
  def discard_payload(path)
    File.delete(path) if File.file?(path)
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

  # The `cases/1` schema name for one format: the middle segment is the input
  # format, so an AsciiMath group declares `plurimath-corpus/asciimath/1`.
  def case_schema(format)
    "plurimath-corpus/#{format.name}/1"
  end

  # The `cases/2` schema name. Same case shape as `case_schema`, except that
  # every target carries an OUTCOME — a rendering or a refusal — instead of a
  # string. Used only by the groups that need it: the `cases/1` groups are not
  # converted, not rewritten, and not deprecated.
  def outcome_case_schema(format)
    "plurimath-corpus/#{format.name}/2"
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

  # Writes every payload for one input format and returns them as the
  # [path, written bytes] pairs `write_provenance` takes, paired with the
  # tally the run summary prints. Each format writes into its own directory,
  # which scripts/validate.rb reconciles with the payloads' `input_format`.
  def write_format(out_root, format)
    payloads = []
    counts = Hash.new(0)

    build_corpus(format).each do |name, description, cases|
      payload = {
        "schema" => case_schema(format),
        "group" => name,
        "description" => description,
        "input_format" => format.name,
        "targets" => format.targets,
        "cases" => cases,
      }
      path = File.join(out_root, format.name, "#{name}.yaml")
      header = payload_header("#{format.label} conformance cases: #{name}.")
      bytes = write_payload(path, header, payload)
      payloads << [path, bytes]
      counts[:cases] += cases.length
      counts[:groups] += 1
    end

    # `cases` is `minItems: 1` in all three payload schemas, so a format with
    # no candidates of a kind writes no payload of that kind rather than an
    # empty one no schema accepts. The two statements differ: an empty payload
    # would claim the format has no partially renderable inputs and no
    # rejections at all, while an absent one claims only that none are recorded
    # yet — which is what a corpus grown one slice per format actually knows.
    partial_cases = build_partial_cases(format)
    partial_path = File.join(out_root, format.name, "#{PARTIAL_GROUP}.yaml")
    if partial_cases.empty?
      discard_payload(partial_path)
    else
      partial_payload = {
        "schema" => outcome_case_schema(format),
        "group" => PARTIAL_GROUP,
        "description" => PARTIAL_DESCRIPTION,
        "input_format" => format.name,
        "targets" => format.targets,
        "cases" => partial_cases,
      }
      partial_bytes = write_payload(
        partial_path,
        payload_header("#{format.label} conformance cases: #{PARTIAL_GROUP}."),
        partial_payload,
      )
      payloads << [partial_path, partial_bytes]
    end

    rejections = build_rejections(format)
    rejection_path = File.join(out_root, format.name, "rejections.yaml")
    if rejections.empty?
      discard_payload(rejection_path)
    else
      rejection_payload = {
        "schema" => REJECTIONS_SCHEMA,
        "group" => "rejections",
        "description" => format.rejection_description,
        "input_format" => format.name,
        "cases" => rejections,
      }
      rejection_bytes = write_payload(
        rejection_path,
        payload_header("#{format.label} rejection cases."),
        rejection_payload,
      )
      payloads << [rejection_path, rejection_bytes]
    end
    counts[:partial] = partial_cases.length
    counts[:rejections] = rejections.length

    [payloads, counts]
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

    out_root = options[:out]
    payloads = []
    # One provenance document covers the whole corpus, so the formats are
    # written before it, and their tallies added up for the summary line.
    counts = Hash.new(0)

    FORMATS.each do |format|
      format_payloads, format_counts = write_format(out_root, format)
      payloads.concat(format_payloads)
      format_counts.each { |key, value| counts[key] += value }
    end

    provenance_path = write_provenance(out_root, provenance, payloads)

    payloads.map(&:first).sort.each do |payload_path|
      puts "  #{relative(payload_path, REPO_ROOT)}"
    end
    puts "  #{relative(provenance_path, REPO_ROOT)}"
    puts "#{counts[:cases]} cases in #{counts[:groups]} groups, " \
         "#{counts[:partial]} partially renderable (cases/2), " \
         "#{counts[:rejections]} rejections"
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
