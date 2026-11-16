# frozen_string_literal: true

# Writes generation 1 of the openmath stage corpus: the payloads and the
# provenance.yaml of stages/openmath/generations/000001.
#
# Run it inside a checkout of the openmath gem, in the gem's own bundle:
#
#   cd openmath && bundle exec ruby <testsuite>/scripts/generate-openmath-stage.rb \
#     --cds <OpenMath/CDs checkout> --omsvn <OpenMath/OMSVN checkout> \
#     --testsuite <this checkout> --generator-commit <sha> --out <generation dir>
#
# Every input is read from a git checkout whose commit is recorded, and every
# file read is listed with its sha256 in provenance.yaml. An expectation is
# what the pinned gem returns; the generator never edits, mutes or drops a
# source object. See docs/openmath-stage.adoc.

require "yaml"
require "fileutils"
require "json"
require "digest"
require "open3"
require "nokogiri"
require "openmath"
require_relative "generate-xml-stage-cases"

module OpenmathStage
  T = XmlStageCases
  VERSIONS = [2, 3].freeze
  SCHEMA = "plurimath-stage/openmath/cases/1"
  CDS_URL = "https://github.com/OpenMath/CDs"
  OMSVN_URL = "https://github.com/OpenMath/OMSVN"
  GEM_URL = "https://github.com/plurimath/openmath"
  SUITE_URL = "https://github.com/plurimath/plurimath-testsuite"
  OM2_DIR = "www/standard/om20-2013-07-11"
  OM3_CD_DIR = "OpenMath3-effort-2009/cd/Official"
  VECTORS = {
    1 => [[0], [1], [-2], [5]],
    2 => [[0, 1], [2, 3], [-4, 5], [7, 7]],
    3 => [[1, 2, 3], [-1, 0, 4], [2, 2, 2]],
  }.freeze

  module_function

  def sha(text) = Digest::SHA256.hexdigest(text)

  def git_head(dir)
    out, st = Open3.capture2("git", "-C", dir, "rev-parse", "HEAD")
    abort "not a git checkout: #{dir}" unless st.success?
    out.strip
  end

  def slug(text) = text.downcase.tr("_", "-")

  def tstr(text) = T.tag_string(text)

  def row(id, input, options, expected, spec = nil)
    r = { "id" => id, "input" => tstr(input), "options" => options }
    r["spec"] = spec if spec
    r["expected"] = expected
    r
  end

  def refusal(stage, error)
    { "refusal" => { "category" => stage,
                     "error_class" => error.class.name } }
  end

  # One OpenMath object on one version: the typed model and the serialized
  # bytes, or the refusal with the raising stage.
  def roundtrip_expected(xml, version)
    begin
      model = Openmath.parse(xml, version: version)
    rescue StandardError => e
      return refusal("parse_error", e)
    end
    begin
      out = model.to_xml
    rescue StandardError => e
      return refusal("serialize_error", e)
    end
    { "model" => T.tag(model), "output" => tstr(out) }
  rescue T::Untaggable => e
    refusal("tag_error", e)
  end

  def validation_expected(xml, version)
    errors = Openmath::Validation.validate(xml, version: version)
    { "model" => { "bool" => errors.empty? },
      "output" => { "int" => errors.size.to_s } }
  rescue StandardError => e
    refusal("validation_error", e)
  end

  # --- sources ------------------------------------------------------------

  # Every OMOBJ element of a CD file, serialized the way the gem's own corpus
  # vendoring does it (scripts/vendor_corpus.rb).
  def cd_objects(path)
    doc = Nokogiri::XML(File.read(path))
    doc.xpath("//*[local-name()='OMOBJ']").map do |omobj|
      kind = omobj.ancestors.map(&:name).include?("FMP") ? "fmp" : "example"
      [kind, omobj.to_xml.rstrip + "\n"]
    end
  end

  # OMOBJ blocks of the standard's CDATA literal layouts. A block is adopted
  # only when it is one well-formed object; the rest are listed with a reason.
  def standard_blocks(text)
    adopted = []
    skipped = []
    text.scan(/<!\[CDATA\[(.*?)\]\]>/m).flatten.each do |block|
      line = text[0, text.index(block)].count("\n") + 1
      next unless block =~ /<OM(OBJ|A|S|I|V|STR|F|B|BIND|E|ATTR)\b/

      stripped = block.strip
      if stripped.scan("<OMOBJ").size > 1 && stripped.match?(/<OMOBJ[^>]*>\s+<OMOBJ/)
        skipped << [line, "two objects side by side in one layout"]
      elsif stripped.scan("<OMOBJ").size > 1
        skipped << [line, "two objects side by side in one layout"]
      elsif !stripped.start_with?("<OMOBJ")
        skipped << [line, "fragment without an OMOBJ wrapper"]
      elsif Nokogiri::XML(stripped) { |c| c.norecover }.errors.any?
        skipped << [line, "not well-formed XML as printed"]
      else
        adopted << [line, stripped + "\n"]
      end
    end
    [adopted, skipped]
  end

  # --- evaluation -----------------------------------------------------------

  def wire_value(value)
    case value
    when true, false then { "kind" => "boolean", "value" => value }
    when Integer then { "kind" => "integer", "value" => value.to_s }
    when Rational
      { "kind" => "rational", "numerator" => value.numerator.to_s,
        "denominator" => value.denominator.to_s }
    when Float then { "kind" => "float", "value" => value.inspect }
    when String then { "kind" => "string", "value" => value }
    when Openmath::Evaluation::ErrorValue
      { "kind" => "error", "cd" => value.cd.to_s, "name" => value.name.to_s,
        "arguments" => value.arguments.map { |a| wire_value(a) } }
    else { "kind" => value.class.name }
    end
  end

  def tag_scalar(value)
    case value
    when true, false then { "bool" => value }
    when Integer then { "int" => value.to_s }
    when Rational
      { "node" => "Rational",
        "fields" => [["numerator", { "int" => value.numerator.to_s }],
                     ["denominator", { "int" => value.denominator.to_s }]] }
    when Float then { "float" => value.inspect }
    when String then tstr(value)
    when Openmath::Evaluation::ErrorValue
      { "node" => value.class.name,
        "fields" => [["cd", tstr(value.cd.to_s)],
                     ["name", tstr(value.name.to_s)],
                     ["arguments",
                      { "array" => value.arguments.map { |a| tag_scalar(a) } }]] }
    else { "node" => value.class.name, "fields" => [] }
    end
  end

  # The canonical JSON the evaluation rows hold as their wire: no spaces,
  # keys in the order written here.
  def wire(result)
    JSON.generate(result)
  end

  def evaluate_expected(xml, vars, table)
    value = Openmath.evaluate(xml, variables: vars, table: table)
    { "model" => tag_scalar(value),
      "output" => tstr(wire("ok" => true, "value" => wire_value(value))) }
  rescue StandardError => e
    cls = e.class.name
    { "refusal" => { "category" => "evaluation_error", "error_class" => cls } }
  end

  def evaluation_options(vars, table_sha)
    { "variables" => JSON.generate(vars),
      "binding_table" => "openmath-binding-table/1",
      "binding_table_sha256" => table_sha }
  end

  # The body of an FMP's forall binder, as a standalone object, with the
  # variables the binder quantifies over left free.
  def fmp_body(xml)
    doc = Nokogiri::XML(xml)
    root = doc.root
    child = root.element_children.first
    binder = child
    if child.name == "OMBIND" &&
       child.element_children.first&.[]("name") == "forall"
      body = child.element_children[2]
      return "<OMOBJ version=\"2.0\">#{body.to_xml}</OMOBJ>\n"
    end
    return nil if xml.include?("<OMBIND")

    binder && xml
  end

  def free_vars(xml)
    Nokogiri::XML(xml).xpath("//OMV").map { |n| n["name"] }.uniq
  end

  def vectors_for(vars, kind)
    return [] if vars.empty?

    if kind == :boolean
      [true, false].repeated_permutation(vars.size).to_a
    else
      VECTORS[vars.size] || []
    end
  end

  # --- payload assembly ------------------------------------------------------

  def payload(group, boundary, description, cases)
    { "schema" => SCHEMA, "group" => group, "description" => description,
      "boundary" => boundary, "cases" => cases }
  end

  def dump(payload)
    "# Written by plurimath-testsuite scripts/generate-openmath-stage.rb. " \
      "Do not edit.\n" + YAML.dump(payload)
  end

  def cd_summary(xml)
    doc = Openmath.parse_cd(xml)
    errors = Openmath::CD::Collection.validate(xml)
    defs = doc.definition_value.map do |d|
      { "hash" => [[{ "str" => "name" }, tstr(d.name.to_s)],
                   [{ "str" => "role" }, tstr(d.role.to_s)],
                   [{ "str" => "cmp" }, { "int" => d.cmp_value.size.to_s }],
                   [{ "str" => "fmp" }, { "int" => d.fmp_value.size.to_s }],
                   [{ "str" => "example" },
                    { "int" => d.example_value.size.to_s }]] }
    end
    meta = %i[cd_name cd_base cd_status cd_version cd_revision].map do |a|
      [{ "str" => a.to_s }, tstr(doc.public_send(a).to_s)]
    end
    { "model" => { "hash" => meta + [[{ "str" => "definitions" },
                                       { "array" => defs }],
                                      [{ "str" => "validation_errors" },
                                       { "int" => errors.size.to_s }]] },
      "output" => tstr(doc.to_xml) }
  rescue StandardError => e
    refusal("parse_error", e)
  end

  def main(argv)
    opts = {}
    argv.each_slice(2) { |k, v| opts[k.sub(/\A--/, "")] = v }
    %w[cds omsvn testsuite generator-commit out].each do |k|
      abort "missing --#{k}" unless opts[k]
    end
    cds = opts["cds"]
    omsvn = opts["omsvn"]
    out = opts["out"]
    gem_root = Dir.pwd
    table_path = File.join(gem_root, "data", "binding-table-1.yml")
    table_text = File.binread(table_path)
    table_sha = sha(table_text)
    table = nil # the gem's default table, whose file is table_path

    cds_commit = git_head(cds)
    omsvn_commit = git_head(omsvn)
    gem_commit = git_head(gem_root)
    gen_path = "scripts/generate-openmath-stage.rb"
    gen_sha = sha(File.binread(File.join(opts["testsuite"], gen_path)))

    FileUtils.mkdir_p(File.join(out, "payloads"))
    inputs = []
    note_input = lambda do |repo, commit, base, rel, text|
      inputs << { "repository" => repo, "commit" => commit,
                  "path" => rel, "sha256" => sha(text), "_base" => base }
    end
    payloads = []
    write = lambda do |name, pl|
      text = dump(pl)
      File.binwrite(File.join(out, "payloads", "#{name}.yaml"), text)
      payloads << { "path" => "payloads/#{name}.yaml", "bytes" => text.bytesize,
                    "sha256" => sha(text),
                    "rows" => pl["cases"].map { |c| c["id"] } }
    end

    note_input.call(GEM_URL, gem_commit, gem_root, "data/binding-table-1.yml", table_text)

    # Official CDs: rows per object, both versions.
    official = Dir[File.join(cds, "cd/Official/*.ocd")].sort_by(&:b)
    validation = []
    counts = Hash.new(0)
    official.each do |path|
      text = File.binread(path)
      rel = "cd/Official/#{File.basename(path)}"
      note_input.call(CDS_URL, cds_commit, cds, rel, text)
      cd = File.basename(path, ".ocd")
      rows = []
      cd_objects(path).each_with_index do |(kind, xml), i|
        n = format("%03d", i + 1)
        VERSIONS.each do |v|
          base = "openmath-#{cd}-#{n}-v#{v}"
          opt = { "version" => v.to_s }
          spec = { "document" => "OpenMath CD #{cd}", "section" => "#{kind} #{i + 1}" }
          e = roundtrip_expected(xml, v)
          counts[e.key?("refusal") ? "roundtrip-refusal" : "roundtrip"] += 1
          rows << row("#{base}.model-roundtrip", xml, opt, e, spec)
          validation << row("#{base}.validation", xml, opt, validation_expected(xml, v), spec)
        end
      end
      next if rows.empty?

      write.call("roundtrip-#{slug(cd)}",
                 payload("roundtrip-#{slug(cd)}", "model-roundtrip",
                         "Openmath.parse and to_xml for every OpenMath object in the official #{cd} content dictionary, on OpenMath 2 and OpenMath 3. A refusal names the raising stage and exception class.",
                         rows))
    end
    write.call("validation-official-cds",
               payload("validation-official-cds", "validation",
                       "Schema verdict (model: valid or not; output: number of schema errors) of every object of the official content dictionaries against the OpenMath 2 and OpenMath 3 schemas.",
                       validation))

    # Standard examples.
    std_path = File.join(omsvn, OM2_DIR, "omstd20.xml")
    std_text = File.binread(std_path)
    note_input.call(OMSVN_URL, omsvn_commit, omsvn, "#{OM2_DIR}/omstd20.xml", std_text)
    adopted, skipped = standard_blocks(std_text.force_encoding("UTF-8"))
    rows = []
    vrows = []
    adopted.each do |line, xml|
      VERSIONS.each do |v|
        base = "openmath-standard-l#{line}-v#{v}"
        opt = { "version" => v.to_s }
        spec = { "document" => "OpenMath 2.0 standard (omstd20.xml)", "section" => "line #{line}" }
        rows << row("#{base}.model-roundtrip", xml, opt, roundtrip_expected(xml, v), spec)
        vrows << row("#{base}.validation", xml, opt, validation_expected(xml, v), spec)
      end
    end
    write.call("roundtrip-standard-examples",
               payload("roundtrip-standard-examples", "model-roundtrip",
                       "Openmath.parse and to_xml for each complete OMOBJ printed in the OpenMath 2.0 standard source, on OpenMath 2 and OpenMath 3. Ids carry the source line of omstd20.xml.", rows))
    write.call("validation-standard-examples",
               payload("validation-standard-examples", "validation",
                       "Schema verdict of each complete OMOBJ printed in the OpenMath 2.0 standard source, on OpenMath 2 and OpenMath 3.", vrows))

    # OpenMath 3 effort draft CDs.
    rows = []
    vrows = []
    om3 = Dir[File.join(omsvn, OM3_CD_DIR, "*.ocd")].sort_by(&:b)
    om3.each do |path|
      text = File.binread(path)
      note_input.call(OMSVN_URL, omsvn_commit, omsvn, "#{OM3_CD_DIR}/#{File.basename(path)}", text)
      cd = File.basename(path, ".ocd")
      cd_objects(path).each_with_index do |(kind, xml), i|
        VERSIONS.each do |v|
          base = "openmath-om3draft-#{cd}-#{format('%03d', i + 1)}-v#{v}"
          opt = { "version" => v.to_s }
          spec = { "document" => "OpenMath 3 effort CD #{cd}", "section" => "#{kind} #{i + 1}" }
          rows << row("#{base}.model-roundtrip", xml, opt, roundtrip_expected(xml, v), spec)
          vrows << row("#{base}.validation", xml, opt, validation_expected(xml, v), spec)
        end
      end
    end
    write.call("roundtrip-om3-draft-cds",
               payload("roundtrip-om3-draft-cds", "model-roundtrip",
                       "Openmath.parse and to_xml for every OpenMath object in the OpenMath 3 effort draft content dictionaries, on OpenMath 2 and OpenMath 3.", rows))
    write.call("validation-om3-draft-cds",
               payload("validation-om3-draft-cds", "validation",
                       "Schema verdict of every object of the OpenMath 3 effort draft content dictionaries, on OpenMath 2 and OpenMath 3.", vrows))

    # CD loading.
    crow = []
    sources = official.map { |p| ["cd/Official", p, cds_commit, cds] } +
              om3.map { |p| [OM3_CD_DIR, p, omsvn_commit, omsvn] }
    %w[arith1 error meta].each do |n|
      p2 = File.join(omsvn, OM2_DIR, "#{n}.ocd")
      text = File.binread(p2)
      note_input.call(OMSVN_URL, omsvn_commit, omsvn, "#{OM2_DIR}/#{n}.ocd", text)
      sources << [OM2_DIR, p2, omsvn_commit, omsvn]
    end
    sources.each do |dir, path, _commit, _root|
      text = File.binread(path)
      tag = dir == "cd/Official" ? "official" : (dir == OM3_CD_DIR ? "om3draft" : "om2std")
      id = "openmath-cd-#{tag}-#{slug(File.basename(path, '.ocd'))}"
      crow << row("#{id}.cd-loading", text, { "source" => tag },
                  cd_summary(text.dup.force_encoding("UTF-8")))
    end
    coll = Openmath::CD::Collection.new.load(File.join(cds, "cd/Official"))
    [["arith1", "plus"], ["relation1", "eq"], ["nums1", "rational"],
     ["arith1", "no_such_symbol"], ["no_such_cd", "plus"]].each do |cd, name|
      d = coll.resolve(cd: cd, name: name)
      crow << row("openmath-cd-resolve-#{slug(cd)}-#{slug(name)}.cd-loading",
                  "#{cd}##{name}", { "collection" => "official" },
                  { "model" => { "bool" => !d.nil? },
                    "output" => tstr(d ? d.role.to_s : "") })
    end
    write.call("cd-loading",
               payload("cd-loading", "cd-loading",
                       "Openmath.parse_cd summary and serialized bytes for every content dictionary read (official CDs, OpenMath 3 effort drafts, the CDs of the OpenMath 2.0 standard directory), plus symbol resolution against the loaded official collection (model: found; output: the symbol's role).", crow))

    # Evaluation.
    erows = []
    frows = []
    official.each do |path|
      cd = File.basename(path, ".ocd")
      cd_objects(path).each_with_index do |(kind, xml), i|
        n = format("%03d", i + 1)
        if kind == "example"
          next if xml.include?("<OMV") || xml.include?("<OMBIND")

          ev = evaluate_expected(xml, {}, table)
          next if ev.key?("refusal") && ev["refusal"]["error_class"].end_with?("UnboundSymbolError")

          erows << row("openmath-eval-#{cd}-example-#{n}.evaluation", xml,
                       evaluation_options({}, table_sha), ev,
                       { "document" => "OpenMath CD #{cd}", "section" => "example #{i + 1}" })
        else
          body = fmp_body(xml)
          next unless body

          vars = free_vars(body)
          kind_v = cd == "logic1" ? :boolean : :integer
          vectors_for(vars, kind_v).each_with_index do |vec, j|
            vh = vars.zip(vec).to_h
            ev = evaluate_expected(body, vh, table)
            next if ev.key?("refusal") && ev["refusal"]["error_class"].end_with?("UnboundSymbolError")

            frows << row("openmath-eval-#{cd}-fmp-#{n}-v#{j + 1}.evaluation", body,
                         evaluation_options(vh, table_sha), ev,
                         { "document" => "OpenMath CD #{cd}", "section" => "fmp #{i + 1}, binder removed" })
          end
        end
      end
    end
    write.call("evaluation-closed-examples",
               payload("evaluation-closed-examples", "evaluation",
                       "Openmath.evaluate under the pinned binding table (binding_table_sha256) for each closed example object of the official content dictionaries that the table can resolve. Model: the value; output: its canonical JSON wire.", erows))
    write.call("evaluation-fmp-instances",
               payload("evaluation-fmp-instances", "evaluation",
                       "Openmath.evaluate under the pinned binding table for the body of each official formal mathematical property whose symbols the table binds, with its forall binder removed and the free variables bound by fixed vectors (options.variables, JSON). Model: the value; output: its canonical JSON wire. A refusal is the exception class the evaluator raised.", frows))

    stats = { "counts" => counts, "skipped_standard" => skipped,
              "adopted_standard" => adopted.map(&:first),
              "evaluation_rows" => erows.size + frows.size }
    File.write(ENV["STATS"], JSON.pretty_generate(stats)) if ENV["STATS"]
    write_provenance(out, opts, gem_commit, cds_commit, omsvn_commit, gen_path, gen_sha, inputs, payloads, skipped)
    warn "payloads=#{payloads.size} rows=#{payloads.sum { |p| p['rows'].size }} #{stats.to_json}"
  end

  def lock_facts
    text = File.read("Gemfile.lock")
    resolved = text.scan(/^    ([a-z0-9_.-]+) \(([^)\s-]+(?:-[a-z0-9.]+)?)\)$/)
                   .to_h.sort.to_h
    git = text[/^GIT\n(.*?)\n\n/m, 1].to_s
    { "text" => text, "resolved" => resolved,
      "bundler" => text[/^BUNDLED WITH\n\s+(\S+)/, 1],
      "git" => { "repository" => git[/remote: (\S+)/, 1],
                 "branch" => git[/branch: (\S+)/, 1],
                 "revision" => git[/revision: (\S+)/, 1] } }
  end

  def environment
    lock = lock_facts
    { "ruby" => { "engine" => RUBY_ENGINE, "version" => RUBY_VERSION },
      "xml_engine" => "nokogiri #{Nokogiri::VERSION}",
      "lockfile" => { "path" => "Gemfile.lock", "committed" => false,
                      "sha256" => sha(lock["text"]),
                      "bundler" => lock["bundler"],
                      "git_sources" => { "lutaml-model" => lock["git"] },
                      "resolved" => lock["resolved"] },
      "dependencies" => lock["resolved"].slice("lutaml-model", "moxml",
                                               "nokogiri"),
      "compiler" => nil, "binding" => nil, "lml" => nil }
  end

  def write_provenance(out, opts, gem_commit, cds_commit, omsvn_commit, gen_path, gen_sha, inputs, payloads, skipped)
    inputs = inputs.map { |i| i.reject { |k, _| k == "_base" } }
                   .sort_by { |i| [i["repository"], i["path"].b] }
    skip_note = skipped.map { |l, r| "line #{l} (#{r})" }.join("; ")
    doc = {
      "schema" => "plurimath-stage/provenance/1",
      "language" => "openmath",
      "generation" => 1,
      "notes" => "Initial openmath generation. Typed-model and serialized-output rows of " \
                 "Openmath.parse (OpenMath 2 and 3) for every object of the official content " \
                 "dictionaries (OpenMath/CDs), the complete objects of the OpenMath 2.0 standard " \
                 "source and the OpenMath 3 effort draft CDs (OMSVN); schema-verdict rows; " \
                 "content-dictionary loading rows; and evaluation rows bound to the gem's " \
                 "binding table. Standard blocks not adopted: #{skip_note}. Written by " \
                 "scripts/generate-openmath-stage.rb; see docs/openmath-stage.adoc.",
      "producers" => {
        "openmath" => {
          "kind" => "stage-gem",
          "repository" => GEM_URL,
          "commit" => gem_commit,
          "version" => Openmath::VERSION,
          "generator" => { "repository" => SUITE_URL, "commit" => opts["generator-commit"],
                           "path" => gen_path, "sha256" => gen_sha },
          "inputs" => inputs,
          "environment" => environment,
          "semantic_boundary" => "model-roundtrip",
          "configuration" => { "entry_point" => "Openmath.parse", "versions" => %w[2 3],
                               "serializer" => "to_xml" },
        },
      },
      "payloads" => payloads.map do |p|
        { "path" => p["path"], "bytes" => p["bytes"], "sha256" => p["sha256"],
          "producer" => "openmath", "source" => { "relation" => "generated", "file" => nil },
          "rows" => p["rows"] }
      end,
    }
    File.binwrite(File.join(out, "provenance.yaml"),
                  "# Generation 1 of the openmath stage corpus. Immutable: never edit this\n" \
                  "# directory; add a new generation instead. See docs/stage-corpus-contract.adoc.\n" +
                  YAML.dump(doc))
  end
end

OpenmathStage.main(ARGV) if $PROGRAM_NAME == __FILE__
