# frozen_string_literal: true

# scripts/validate-stages.rb guards the immutable stage generations. Each
# example below breaks one rule of docs/stage-corpus-contract.adoc in a copy
# of a small healthy tree and expects the validator to refuse it; the healthy
# tree and the repository's own stages must pass.
#
# The validator runs as a child process with --disable-gems, the same way CI
# runs it, so it must stay gem-free.

STAGE_VALIDATOR = File.join(REPO_ROOT, "scripts", "validate-stages.rb")
require STAGE_VALIDATOR

RSpec.describe "scripts/validate-stages.rb" do
  let(:healthy) { fixture("stages/healthy") }
  let(:latex_gen1) { "stages/latex/generations/000001" }
  let(:latex_smoke) { "#{latex_gen1}/payloads/smoke.yaml" }

  def run_stages(*argv)
    capture = lambda do
      Open3.capture3(RbConfig.ruby, "--disable-gems", STAGE_VALIDATOR,
                     *argv, chdir: REPO_ROOT)
    end
    out, err, status =
      defined?(Bundler) ? Bundler.with_unbundled_env(&capture) : capture.call
    [status.exitstatus, out + err]
  end

  def with_tree
    Dir.mktmpdir("testsuite-stages") do |dir|
      FileUtils.cp_r(File.join(healthy, "."), dir)
      yield dir
    end
  end

  def git(dir, *args)
    out, err, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')}: #{err}" unless status.success?

    out.strip
  end

  def commit_all(dir, message)
    git(dir, "add", "-A")
    git(dir, "-c", "user.name=spec", "-c", "user.email=spec@example.test",
        "commit", "-q", "-m", message)
    git(dir, "rev-parse", "HEAD")
  end

  def with_repo
    with_tree do |dir|
      git(dir, "init", "-q")
      yield dir, commit_all(dir, "base")
    end
  end

  def edit_yaml(path)
    document = YAML.safe_load_file(path, aliases: false)
    yield document
    # A round trip through JSON unshares repeated objects, which YAML.dump
    # would otherwise write as aliases the validator rightly refuses.
    File.write(path, YAML.dump(JSON.parse(JSON.generate(document))))
  end

  # Recomputes the provenance sizes/sha256s/row lists and the ledger digests
  # of the named generations (relative paths), so the only thing wrong with a
  # tree is the rule a test is about. Other files are left byte for byte.
  def restamp(dir, *generations)
    Dir.glob(File.join(dir, "generations", "*.yaml")).each do |ledger_path|
      listed = YAML.safe_load_file(ledger_path)["entries"]
        .map { |e| e["path"] } & generations
      next if listed.empty?

      edit_yaml(ledger_path) do |ledger|
        ledger["entries"].each do |entry|
          next unless listed.include?(entry["path"])

          gen = File.join(dir, entry["path"])
          names = Dir.children(File.join(gen, "payloads")).sort
          edit_yaml(File.join(gen, "provenance.yaml")) do |provenance|
            producer = provenance["payloads"].first["producer"]
            source = provenance["payloads"].first["source"]
            provenance["payloads"] = names.map do |name|
              bytes = File.binread(File.join(gen, "payloads", name))
              { "path" => "payloads/#{name}", "bytes" => bytes.bytesize,
                "sha256" => Digest::SHA256.hexdigest(bytes),
                "producer" => producer, "source" => source,
                "rows" => YAML.safe_load(bytes)["cases"].map { |c| c["id"] } }
            end
            entry["payloads"] = names.length
            entry["rows"] = provenance["payloads"].sum { |p| p["rows"].length }
          end
          files = (names.map { |n| "payloads/#{n}" } + ["provenance.yaml"])
            .map { |p| [p, File.binread(File.join(gen, p))] }
          entry["snapshot_digest"] = Testsuite::Stages.snapshot_digest(files)
        end
      end
    end
  end

  # Generation 2 of latex: a copy of generation 1 plus one more case.
  def add_latex_generation(dir)
    gen2 = File.join(dir, "stages/latex/generations/000002")
    FileUtils.cp_r(File.join(dir, latex_gen1), gen2)
    edit_yaml(File.join(gen2, "provenance.yaml")) { |p| p["generation"] = 2 }
    edit_yaml(File.join(gen2, "payloads/smoke.yaml")) do |payload|
      payload["cases"] << {
        "id" => "smoke-latex-x", "input" => { "str" => "x" },
        "options" => {}, "expected" => {
          "preprocessed" => { "str" => "x" }, "tree" => { "slice" => "x",
                                                          "byte_offset" => 0 }
        }
      }
      yield payload if block_given?
    end
    edit_yaml(File.join(dir, "generations/latex.yaml")) do |ledger|
      ledger["entries"] << ledger["entries"].first.merge(
        "generation" => 2, "path" => "stages/latex/generations/000002",
        "change" => "extend", "rationale" => "Adds one row."
      )
    end
    restamp(dir, "stages/latex/generations/000002")
  end

  describe "trees that hold" do
    it "accepts the repository's own stage generations" do
      status, output = run_stages
      expect(status).to eq(0), output
      expect(output).to include("layout revision 1", "all valid")
    end

    it "accepts the healthy smoke tree, counting its stable rows" do
      status, output = run_stages(healthy)
      expect(status).to eq(0), output
      expect(output).to include("2 ledgers, 2 generations, 2 payloads, 4 rows")
    end

    it "agrees with sha256sum over the sorted file list" do
      gen = File.join(healthy, latex_gen1)
      files = %w[payloads/smoke.yaml provenance.yaml].map do |p|
        [p, File.binread(File.join(gen, p))]
      end
      lines = files.map { |p, b| "#{Digest::SHA256.hexdigest(b)}  #{p}\n" }
      expect(Testsuite::Stages.snapshot_digest(files.reverse))
        .to eq("sha256:#{Digest::SHA256.hexdigest(lines.join)}")
    end

    it "accepts a later generation that keeps every earlier case" do
      with_tree do |dir|
        add_latex_generation(dir)
        status, output = run_stages(dir)
        expect(status).to eq(0), output
      end
    end
  end

  describe "tampering" do
    it "rejects a payload whose bytes no longer match its checksum" do
      with_tree do |dir|
        File.open(File.join(dir, latex_smoke), "a") { |f| f.write("\n") }
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("/payloads/0/sha256", "/payloads/0/bytes")
      end
    end

    it "rejects an edited provenance through the ledger's snapshot digest" do
      with_tree do |dir|
        File.open(File.join(dir, latex_gen1, "provenance.yaml"), "a") do |f|
          f.write("# edited\n")
        end
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("/entries/0/snapshot_digest")
      end
    end

    it "rejects a payload file the provenance does not list" do
      with_tree do |dir|
        FileUtils.cp(File.join(dir, latex_smoke),
                     File.join(dir, latex_gen1, "payloads/extra.yaml"))
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("does not list #{latex_gen1}/payloads/extra")
      end
    end

    it "rejects a listed payload that is missing" do
      with_tree do |dir|
        File.delete(File.join(dir, latex_smoke))
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("lists payloads/smoke.yaml, which is not")
      end
    end

    it "rejects a file outside the allowed layout" do
      with_tree do |dir|
        File.write(File.join(dir, "stages/latex/notes.txt"), "x")
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("stages/latex/notes.txt",
                                  "not a file the stage layout allows")
      end
    end

    it "rejects an unsafe payload path" do
      with_tree do |dir|
        edit_yaml(File.join(dir, latex_gen1, "provenance.yaml")) do |p|
          p["payloads"].first["path"] = "payloads/../../smoke.yaml"
        end
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("/payloads/0/path")
      end
    end

    it "rejects a payload listed twice" do
      with_tree do |dir|
        edit_yaml(File.join(dir, latex_gen1, "provenance.yaml")) do |p|
          p["payloads"] << p["payloads"].first
        end
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("lists payloads/smoke.yaml more than once")
      end
    end

    it "refuses symlinks" do
      with_tree do |dir|
        File.symlink(File.join(dir, latex_smoke),
                     File.join(dir, latex_gen1, "payloads/link.yaml"))
        status, output = run_stages(dir)
        expect(status).to eq(2)
        expect(output).to include("may not contain symlinks")
      end
    end

    it "rejects a payload of another language" do
      with_tree do |dir|
        FileUtils.mv(File.join(dir, "stages/latex"),
                     File.join(dir, "stages/unicode"))
        FileUtils.mv(File.join(dir, "generations/latex.yaml"),
                     File.join(dir, "generations/unicode.yaml"))
        edit_yaml(File.join(dir, "generations/unicode.yaml")) do |ledger|
          ledger["language"] = "unicode"
          ledger["entries"].first["path"] = "stages/unicode/generations/000001"
        end
        edit_yaml(File.join(dir, "stages/unicode/generations/000001/" \
                                 "provenance.yaml")) do |p|
          p["language"] = "unicode"
        end
        restamp(dir, "stages/unicode/generations/000001")
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("does not belong under stages/unicode")
      end
    end
  end

  describe "empty replay" do
    it "fails a tree with no stage files at all" do
      Dir.mktmpdir("testsuite-stages") do |dir|
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("validates nothing is not a pass")
      end
    end

    it "fails a generation whose provenance lists no payloads" do
      with_tree do |dir|
        File.delete(File.join(dir, latex_smoke))
        edit_yaml(File.join(dir, latex_gen1, "provenance.yaml")) do |p|
          p["payloads"] = []
        end
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("/payloads: has 0 item")
      end
    end
  end

  describe "generation sequence" do
    it "rejects a generation directory the ledger does not list" do
      with_tree do |dir|
        FileUtils.cp_r(File.join(dir, latex_gen1),
                       File.join(dir, "stages/latex/generations/000002"))
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("does not list " \
                                  "stages/latex/generations/000002")
      end
    end

    it "rejects a gap in the generation numbers" do
      with_tree do |dir|
        edit_yaml(File.join(dir, "generations/latex.yaml")) do |ledger|
          ledger["entries"] << ledger["entries"].first.merge(
            "generation" => 3, "change" => "extend",
          )
        end
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("/entries/1/generation: is 3")
      end
    end

    it "rejects a later generation that drops an earlier case" do
      with_tree do |dir|
        add_latex_generation(dir) { |payload| payload["cases"].shift }
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("drops case smoke-latex-frac")
      end
    end

    it "rejects a later generation that changes an earlier expectation" do
      with_tree do |dir|
        add_latex_generation(dir) do |payload|
          payload["cases"].first["expected"]["preprocessed"] = { "str" => "" }
        end
        status, output = run_stages(dir)
        expect(status).to eq(1)
        expect(output).to include("case smoke-latex-frac: changes expected " \
                                  "preprocessed")
      end
    end
  end

  describe "--base" do
    it "rejects an edit to a generation the base already has" do
      with_repo do |dir, base|
        File.open(File.join(dir, latex_smoke), "a") { |f| f.write("\n") }
        restamp(dir, latex_gen1)
        expect(run_stages(dir).first).to eq(0) # consistent, but rewritten

        status, output = run_stages(dir, "--base", base)
        expect(status).to eq(1)
        expect(output).to include("#{latex_smoke}\n          differs from base")
      end
    end

    it "rejects a file added to a generation the base already has" do
      with_repo do |dir, base|
        FileUtils.cp(File.join(dir, latex_smoke),
                     File.join(dir, latex_gen1, "payloads/more.yaml"))
        edit_yaml(File.join(dir, latex_gen1, "payloads/more.yaml")) do |p|
          p["group"] = "more"
          p["cases"].each { |c| c["id"] = "more-#{c['id']}" }
        end
        restamp(dir, latex_gen1)
        expect(run_stages(dir).first).to eq(0)

        status, output = run_stages(dir, "--base", base)
        expect(status).to eq(1)
        expect(output).to include("was added to a generation that base")
      end
    end

    it "rejects a rewritten ledger entry" do
      with_repo do |dir, base|
        edit_yaml(File.join(dir, "generations/latex.yaml")) do |ledger|
          ledger["entries"].first["rationale"] = "Rewritten."
        end
        status, output = run_stages(dir, "--base", base)
        expect(status).to eq(1)
        expect(output).to include("not an append-only extension")
      end
    end

    it "rejects a removed language" do
      with_repo do |dir, base|
        FileUtils.rm_r([File.join(dir, "stages/roundtrip"),
                        File.join(dir, "generations/roundtrip.yaml")])
        status, output = run_stages(dir, "--base", base)
        expect(status).to eq(1)
        expect(output).to include("existed at base")
      end
    end

    it "accepts an appended generation" do
      with_repo do |dir, base|
        add_latex_generation(dir)
        status, output = run_stages(dir, "--base", base)
        expect(status).to eq(0), output
        expect(output).to include("earlier generations and ledger entries " \
                                  "unchanged")
      end
    end
  end

  describe "--pin" do
    def write_pin(dir, **overrides)
      ledger = YAML.safe_load_file(File.join(dir, "generations/latex.yaml"))
      pin = {
        "schema" => "plurimath-stage/pin/1",
        "repository" => "https://github.com/plurimath/plurimath-testsuite",
        "commit" => git(dir, "rev-parse", "HEAD"),
        "language" => "latex", "generation" => 1,
        "snapshot_digest" => ledger["entries"].first["snapshot_digest"]
      }.merge(overrides.transform_keys(&:to_s))
      path = File.join(dir, "..", "#{File.basename(dir)}-pin.yml")
      File.write(path, YAML.dump(pin))
      path
    end

    it "accepts a pin of the checkout's commit, generation and digest" do
      with_repo do |dir, _|
        status, output = run_stages(dir, "--pin", write_pin(dir))
        expect(status).to eq(0), output
        expect(output).to include("latex generation 1, 3 rows")
      end
    end

    it "rejects a pin of another commit" do
      with_repo do |dir, _|
        status, output = run_stages(dir, "--pin",
                                    write_pin(dir, commit: "b" * 40))
        expect(status).to eq(1)
        expect(output).to include("/commit: pins #{'b' * 40}")
      end
    end

    it "rejects a pin with the wrong digest" do
      with_repo do |dir, _|
        pin = write_pin(dir, snapshot_digest: "sha256:#{'0' * 64}")
        status, output = run_stages(dir, "--pin", pin)
        expect(status).to eq(1)
        expect(output).to include("/snapshot_digest: pins sha256:0000")
      end
    end

    it "rejects a pin of a generation that does not exist" do
      with_repo do |dir, _|
        status, output = run_stages(dir, "--pin",
                                    write_pin(dir, generation: 2))
        expect(status).to eq(1)
        expect(output).to include("latex has no generation 2")
      end
    end
  end

  describe "parity schemas" do
    def schema(name)
      Testsuite::JsonSchema::Schema.new(
        JSON.parse(File.read(File.join(SpecHelpers::SCHEMA_DIR, name))), name
      )
    end

    let(:capture) { YAML.safe_load_file(fixture("stages/parity/capture.yaml")) }
    let(:report) { YAML.safe_load_file(fixture("stages/parity/report.yaml")) }

    it "accepts a capture with every row status" do
      expect(schema("stage-parity-capture.json").validate(capture)).to eq([])
    end

    it "requires a refusal on a refused row" do
      capture["rows"][1].delete("refusal")
      expect(schema("stage-parity-capture.json").validate(capture)).not_to eq([])
    end

    it "accepts a passing report" do
      expect(schema("stage-parity-report.json").validate(report)).to eq([])
    end

    it "does not let a report pass with a crashed row" do
      report["counts"]["crashed"] = 1
      expect(schema("stage-parity-report.json").validate(report)).not_to eq([])
    end

    it "does not let a report pass with a mismatch" do
      report["mismatches"] << { "id" => "x", "boundary" => "raw",
                                "pointer" => "/hash/0" }
      expect(schema("stage-parity-report.json").validate(report)).not_to eq([])
    end
  end
end
