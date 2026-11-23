# frozen_string_literal: true

# Run inside the recorded plurimath checkout's bundle:
# bundle exec ruby <testsuite>/scripts/generate-openmath-roundtrips.rb --gem <checkout>
# Adds one immutable roundtrip generation, using the native roundtrip generator
# for all expected outputs, loss flags and refusals on both XML engines.
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "yaml"

module OpenmathRoundtrips
  ROOT = File.expand_path("..", __dir__)
  REPOSITORY = "https://github.com/plurimath/plurimath-testsuite"
  SCRIPT = "scripts/generate-openmath-roundtrips.rb"
  PRESENTATION = %w[asciimath latex unicode mathml omml html].freeze
  # Inputs only. Expected results are always obtained from the running oracle.
  OBJECTS = {
    "addition" => '<OMA><OMS cd="arith1" name="plus"/><OMI>2</OMI><OMI>3</OMI></OMA>',
    "division" => '<OMA><OMS cd="arith1" name="divided_by"/><OMV name="x"/><OMI>4</OMI></OMA>',
    "precedence" => '<OMA><OMS cd="arith1" name="times"/><OMA><OMS cd="arith1" name="plus"/><OMI>1</OMI><OMI>2</OMI></OMA><OMI>3</OMI></OMA>',
    "unbound-symbol" => '<OMS cd="custom" name="alpha" cdbase="https://example.org/cd"/>',
    "binding" => '<OMBIND><OMS cd="fns1" name="lambda"/><OMBVAR><OMV name="x"/></OMBVAR><OMV name="x"/></OMBIND>',
    "error" => '<OME><OMS cd="error" name="unexpected"/><OMSTR>bad</OMSTR></OME>',
  }.freeze
  MAPPED = %w[addition division precedence].freeze

  module_function

  def git(root, *args)
    out, err, status = Open3.capture3("git", "-C", root, *args)
    raise "git #{args.join(' ')}: #{err}" unless status.success?

    out.strip
  end

  def file(root, repository, path)
    { "repository" => repository, "commit" => git(root, "rev-parse", "HEAD"),
      "path" => path, "sha256" => Digest::SHA256.file(File.join(root, path)).hexdigest }
  end

  def xml(body)
    %(<OMOBJ xmlns="http://www.openmath.org/OpenMath">#{body}</OMOBJ>)
  end

  def entry(id, language, input)
    [id, language, input, {}, ["plurimath docs/openmath.adoc", "Supported surface"]]
  end

  def payload
    entries = OBJECTS.flat_map do |id, body|
      input = xml(body)
      result = [entry("#{id}-from-openmath", "openmath", input)]
      if MAPPED.include?(id)
        formula = RoundtripCases.parse(input, "openmath", {})
        PRESENTATION.each do |notation|
          text = formula.public_send(RoundtripCases::WRITERS.fetch(notation))
          result << entry("#{id}-from-#{notation}", notation, text)
        end
      end
      result
    end
    entries << entry("uncertainty-to-openmath", "asciimath", '"ustd(1.2,0.1)"')
    entries << entry("unbound-function-to-openmath", "asciimath", "sin(x)")
    RoundtripCases.payload("openmath-integration",
      "OpenMath and all six presentation notations; unsupported semantic and presentation constructs retain explicit target refusals.", entries)
  end

  def measured_payload
    runs = RoundtripCases::ENGINES.keys.map do |engine|
      RoundtripCases.with_engine(engine) { payload }
    end
    raise "XML engines disagree; nothing written" unless runs.uniq.size == 1

    runs.first
  end

  def producer(gem_root)
    data = RoundtripCases.producer
    data["inputs"] = [data.fetch("generator"),
      file(gem_root, RoundtripCases::REPOSITORY, "docs/openmath.adoc")]
    data["generator"] = file(ROOT, REPOSITORY, SCRIPT)
    openmath = Gem.loaded_specs.fetch("openmath")
    raise "requires published openmath 0.2.1" unless openmath.version.to_s == "0.2.1"

    data["configuration"].merge!(
      "input_notations" => PRESENTATION + ["openmath"],
      "openmath_version" => openmath.version.to_s,
      "openmath_binding_table_sha256" => Digest::SHA256.file(
        File.join(openmath.full_gem_path, "data/binding-table-1.yml")).hexdigest)
    archive = File.join(openmath.base_dir, "cache", "openmath-0.2.1.gem")
    data["configuration"]["openmath_archive_sha256"] = Digest::SHA256.file(archive).hexdigest
    data
  end

  def dump(path, value)
    # Avoid YAML aliases: independent rows and metadata must be portable.
    File.write(path, YAML.dump(JSON.parse(JSON.generate(value))))
  end

  def snapshot_digest(dir)
    lines = Dir.glob("**/*", base: dir).select { |p| File.file?(File.join(dir, p)) }
      .sort_by(&:b).map { |p| "#{Digest::SHA256.file(File.join(dir, p)).hexdigest}  #{p}\n" }
    "sha256:#{Digest::SHA256.hexdigest(lines.join)}"
  end

  def run(argv)
    options = {}
    OptionParser.new { |o| o.on("--gem PATH") { |p| options[:gem] = File.expand_path(p) } }.parse!(argv)
    gem_root = options.fetch(:gem)
    [ROOT, gem_root].each do |root|
      raise "needs a clean checkout: #{root}" unless git(root, "status", "--porcelain").empty?
    end
    require File.join(gem_root, "scripts/roundtrip_cases")
    raise "oracle lacks six-notation roundtrip writers" unless
      (PRESENTATION + ["openmath"] - RoundtripCases::TARGETS).empty?
    data = measured_payload
    block = producer(gem_root)
    ledger_path = File.join(ROOT, "generations/roundtrip.yaml")
    ledger = YAML.safe_load_file(ledger_path)
    previous = ledger.fetch("entries").last
    number = previous.fetch("generation") + 1
    relative = format("stages/roundtrip/generations/%06d", number)
    output = File.join(ROOT, relative)
    raise "already exists: #{output}" if File.exist?(output)

    FileUtils.cp_r(File.join(ROOT, previous.fetch("path")), output)
    provenance = YAML.safe_load_file(File.join(output, "provenance.yaml"))
    provenance["generation"] = number
    provenance["notes"] = "Earlier rows and their producers preserved; OpenMath integration rows measured on Ox and Oga with published openmath 0.2.1."
    provenance.fetch("producers")["openmath-integration"] = block
    path = "payloads/openmath-integration.yaml"
    dump(File.join(output, path), data)
    provenance.fetch("payloads") << {
      "path" => path, "bytes" => File.size(File.join(output, path)),
      "sha256" => Digest::SHA256.file(File.join(output, path)).hexdigest,
      "producer" => "openmath-integration",
      "source" => { "relation" => "generated", "file" => nil },
      "rows" => data.fetch("cases").map { |row| row.fetch("id") }
    }
    provenance["payloads"].sort_by! { |p| p.fetch("path").b }
    dump(File.join(output, "provenance.yaml"), provenance)
    ledger.fetch("entries") << {
      "generation" => number, "path" => relative, "snapshot_digest" => snapshot_digest(output),
      "payloads" => provenance.fetch("payloads").size,
      "rows" => provenance.fetch("payloads").sum { |p| p.fetch("rows").size },
      "producer_kinds" => provenance.fetch("producers").values.map { |p| p.fetch("kind") }.uniq.sort,
      "change" => "extend",
      "rationale" => "plurimath#585: OpenMath 0.2.1 integration across six presentation notations, with measured target refusals; earlier rows unchanged."
    }
    dump(ledger_path, ledger)
    puts "generation #{number}: #{data.fetch('cases').size} new rows"
  end
end

OpenmathRoundtrips.run(ARGV) if $PROGRAM_NAME == __FILE__
