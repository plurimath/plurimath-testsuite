# frozen_string_literal: true

# scripts/validate-unicode-external.rb guards the unicode stage rows written
# for the external UnicodeMath inputs of fixtures/unicode-expectations.yaml.
# Each example below breaks one rule in a small healthy tree (four fixture
# cases instead of 675, checked with --cases 4) and expects the validator to
# refuse it; the healthy tree and the repository's own tree must pass.
#
# The validator runs as a child process with --disable-gems, as CI runs it.

require "json"

EXTERNAL_VALIDATOR = File.join(REPO_ROOT, "scripts",
                               "validate-unicode-external.rb")
require EXTERNAL_VALIDATOR

RSpec.describe "scripts/validate-unicode-external.rb" do
  let(:gen) { "stages/unicode/generations/000001" }
  let(:raw_payload) { "#{gen}/payloads/raw-external-001-004.yaml" }
  let(:model_payload) { "#{gen}/payloads/model-external-001-004.yaml" }
  let(:upstream) do
    { "repository" => "https://github.com/plurimath/unicodemath-tests",
      "revision" => "ac19358ebdd0044cafe769feb121a49aff3230c8",
      "path" => "unicodemath_tests.yaml",
      "sha256" =>
        "1af5f6775afabf7fd7076f85c8378981334885a2d63005f2f6f734695c401c1d" }
  end
  # [lexeme as written in the fixture, its YAML value]
  let(:inputs) do
    [['"0a+b"', "0a+b"], ['"1α"', "1α"], ['"1α"', "1α"], ["10", 10]]
  end

  def run_external(*argv)
    capture = lambda do
      Open3.capture3(RbConfig.ruby, "--disable-gems", EXTERNAL_VALIDATOR,
                     *argv)
    end
    out, err, status =
      defined?(Bundler) ? Bundler.with_unbundled_env(&capture) : capture.call
    [status.exitstatus, out + err]
  end

  def fixture_text(cases = inputs)
    rows = cases.each_with_index.map do |(lexeme, value), i|
      <<~YAML
        - "id": "unicode-external-#{format('%03d', i + 1)}"
          "index": #{i + 1}
          "input": #{lexeme}
          "source":
            "input_index": #{i + 1}
            "input_sha256": "#{Digest::SHA256.hexdigest(JSON.generate(value))}"
      YAML
    end
    <<~YAML + rows.join
      ---
      "schema": "plurimath-fixtures/unicode-expectations/1"
      "source":
        "input": #{JSON.generate(upstream)}
      "cases":
    YAML
  end

  def payload(boundary, prefix, suffix)
    cases = inputs.each_with_index.map do |(_, value), i|
      input = value.to_s[1..]
      { "id" => "unicode-external-#{format('%03d', i + 1)}#{suffix}",
        "input" => { "str" => input }, "options" => { "decimal" => "." },
        "expected" => { "preprocessed" => { "str" => input },
                        "tree" => { "str" => "tree of #{input}" } } }
    end
    { "schema" => "plurimath-stage/unicode/cases/1",
      "group" => "#{prefix}001-004", "description" => "rows",
      "boundary" => boundary, "cases" => cases }
  end

  def producer(boundary, fixture_sha)
    plain = ["unicode-external-004"]
    { "kind" => "stage-gem", "repository" => "https://github.com/plurimath/umath",
      "commit" => "c" * 40, "version" => "0.2.0",
      "generator" => { "repository" => UnicodeExternal::TESTSUITE_REPOSITORY,
                       "commit" => "a" * 40,
                       "path" => UnicodeExternal::GENERATOR_PATH,
                       "sha256" => "0" * 64 },
      "inputs" => [{ "repository" => UnicodeExternal::TESTSUITE_REPOSITORY,
                     "commit" => "a" * 40,
                     "path" => UnicodeExternal::FIXTURE_PATH,
                     "sha256" => fixture_sha }],
      "environment" => {}, "semantic_boundary" => boundary,
      "configuration" => {
        "selection" => {
          "cases" => 4, "plain_scalar_inputs" => plain,
          "duplicate_inputs" => [%w[unicode-external-002
                                    unicode-external-003]]
        },
        "upstream" => UnicodeExternal::UPSTREAM,
        "origin" => UnicodeExternal::ORIGIN
      } }
  end

  def write_yaml(path, document)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, YAML.dump(JSON.parse(JSON.generate(document))))
  end

  def edit_yaml(path)
    document = YAML.safe_load_file(path, aliases: false)
    yield document
    write_yaml(path, document)
  end

  def build_tree(dir)
    fixture = File.join(dir, UnicodeExternal::FIXTURE_PATH)
    FileUtils.mkdir_p(File.dirname(fixture))
    File.write(fixture, fixture_text)
    sha = Digest::SHA256.file(fixture).hexdigest
    FileUtils.mkdir_p(File.join(dir, "LICENSES"))
    FileUtils.cp(File.join(REPO_ROOT, UnicodeExternal::NOTICE_PATH),
                 File.join(dir, UnicodeExternal::NOTICE_PATH))
    write_yaml(File.join(dir, raw_payload),
               payload("raw-tree", "raw-external-", ".raw"))
    write_yaml(File.join(dir, model_payload),
               payload("typed-model", "model-external-", ".model"))
    write_yaml(File.join(dir, "generations/unicode.yaml"),
               "entries" => [{ "generation" => 1, "path" => gen }])
    payloads = [model_payload, raw_payload].map do |path|
      doc = YAML.safe_load_file(File.join(dir, path))
      { "path" => path.delete_prefix("#{gen}/"),
        "producer" => doc["boundary"] == "raw-tree" ? "umath-external-raw" : "umath-external-model",
        "rows" => doc["cases"].map { |c| c["id"] } }
    end
    write_yaml(File.join(dir, gen, "provenance.yaml"),
               "producers" => {
                 "umath-external-raw" => producer("raw-tree", sha),
                 "umath-external-model" => producer("typed-model", sha)
               },
               "payloads" => payloads)
  end

  def with_tree
    Dir.mktmpdir("unicode-external") do |dir|
      build_tree(dir)
      yield dir
    end
  end

  def expect_failure(dir, *messages)
    status, output = run_external(dir, "--cases", "4")
    expect(status).to eq(1), output
    expect(output).to include(*messages)
  end

  def provenance(dir)
    File.join(dir, gen, "provenance.yaml")
  end

  describe "trees that hold" do
    it "accepts the repository's own external generation" do
      status, output = run_external(REPO_ROOT)
      expect(status).to eq(0), output
      expect(output).to include("675 raw-tree, 675 typed-model external rows")
    end

    it "accepts the healthy small tree" do
      with_tree do |dir|
        status, output = run_external(dir, "--cases", "4")
        expect(status).to eq(0), output
        expect(output).to include("4 raw-tree, 4 typed-model external rows")
      end
    end

    it "reads the fixture from the recorded commit when the working copy changed" do
      with_tree do |dir|
        fixture = File.join(dir, UnicodeExternal::FIXTURE_PATH)
        original = File.binread(fixture)
        Open3.capture3("git", "-C", dir, "init", "-q")
        Open3.capture3("git", "-C", dir, "add", "-A")
        Open3.capture3("git", "-C", dir, "-c", "user.name=spec", "-c",
                       "user.email=spec@example.test", "commit", "-q", "-m", "x")
        head, = Open3.capture3("git", "-C", dir, "rev-parse", "HEAD")
        edit_yaml(provenance(dir)) do |p|
          p["producers"].each_value { |b| b["inputs"][0]["commit"] = head.strip }
        end
        File.write(fixture, "#{original}# edited later\n")
        status, output = run_external(dir, "--cases", "4")
        expect(status).to eq(0), output
      end
    end

    it "accepts a complete executed-id list" do
      with_tree do |dir|
        ids = File.join(dir, "executed.txt")
        File.write(ids, (1..4).flat_map do |i|
          %w[raw model].map { |s| "unicode-external-#{format('%03d', i)}.#{s}" }
        end.join("\n"))
        status, output = run_external(dir, "--cases", "4", "--generation",
                                      "1", "--executed", ids)
        expect(status).to eq(0), output
        expect(output).to include("8 of 8 external rows executed")
      end
    end
  end

  describe "tampering it refuses" do
    it "refuses a dropped row" do
      with_tree do |dir|
        edit_yaml(File.join(dir, raw_payload)) { |p| p["cases"].pop }
        edit_yaml(provenance(dir)) { |p| p["payloads"][1]["rows"].pop }
        expect_failure(dir, "3 rows for 4 cases", "unicode-external-004.raw")
      end
    end

    it "refuses reordered rows" do
      with_tree do |dir|
        edit_yaml(File.join(dir, model_payload)) { |p| p["cases"].reverse! }
        edit_yaml(provenance(dir)) { |p| p["payloads"][0]["rows"].reverse! }
        expect_failure(dir, "(order differs)")
      end
    end

    it "refuses a renamed row id" do
      with_tree do |dir|
        edit_yaml(File.join(dir, raw_payload)) do |p|
          p["cases"][0]["id"] = "unicode-external-901.raw"
        end
        edit_yaml(provenance(dir)) do |p|
          p["payloads"][1]["rows"][0] = "unicode-external-901.raw"
        end
        expect_failure(dir, "missing [\"unicode-external-001.raw\"]")
      end
    end

    it "refuses a changed input" do
      with_tree do |dir|
        edit_yaml(File.join(dir, raw_payload)) do |p|
          p["cases"][0]["input"] = { "str" => "0a+b" }
        end
        expect_failure(dir, "unicode-external-001.raw: input")
      end
    end

    it "refuses provenance rows that differ from the file" do
      with_tree do |dir|
        edit_yaml(provenance(dir)) { |p| p["payloads"][1]["rows"].reverse! }
        expect_failure(dir, "provenance rows differ from the file's ids")
      end
    end

    it "refuses duplicate inputs with different outcomes" do
      with_tree do |dir|
        edit_yaml(File.join(dir, model_payload)) do |p|
          p["cases"][2]["expected"]["tree"] = { "str" => "other" }
        end
        expect_failure(dir, "unicode-external-002.model, " \
                            "unicode-external-003.model have the same input")
      end
    end

    it "refuses a fixture whose bytes differ from the recorded sha256" do
      with_tree do |dir|
        File.write(File.join(dir, UnicodeExternal::FIXTURE_PATH),
                   "#{fixture_text}# tampered\n")
        expect_failure(dir, "neither the working tree nor")
      end
    end

    it "refuses a fixture with a case missing" do
      with_tree do |dir|
        fixture = File.join(dir, UnicodeExternal::FIXTURE_PATH)
        File.write(fixture, fixture_text(inputs.first(3)))
        edit_yaml(provenance(dir)) do |p|
          p["producers"].each_value do |b|
            b["inputs"][0]["sha256"] = Digest::SHA256.file(fixture).hexdigest
          end
        end
        expect_failure(dir, "3 cases, expected 4")
      end
    end

    it "refuses an input without its display flag" do
      with_tree do |dir|
        inputs[0] = ['"a+b"', "a+b"]
        build_tree(dir)
        expect_failure(dir, "has no 0/1 display flag")
      end
    end

    it "refuses a wrong input_sha256" do
      with_tree do |dir|
        fixture = File.join(dir, UnicodeExternal::FIXTURE_PATH)
        text = File.read(fixture).sub(/"input_sha256": "[0-9a-f]{8}/,
                                      '"input_sha256": "00000000')
        File.write(fixture, text)
        edit_yaml(provenance(dir)) do |p|
          p["producers"].each_value do |b|
            b["inputs"][0]["sha256"] = Digest::SHA256.file(fixture).hexdigest
          end
        end
        expect_failure(dir, "unicode-external-001: input_sha256")
      end
    end

    it "refuses a selection record that hides a plain-scalar input" do
      with_tree do |dir|
        edit_yaml(provenance(dir)) do |p|
          p["producers"]["umath-external-raw"]["configuration"]["selection"]["plain_scalar_inputs"] = []
        end
        expect_failure(dir, "selection plain_scalar_inputs")
      end
    end

    it "refuses a changed upstream reference" do
      with_tree do |dir|
        edit_yaml(provenance(dir)) do |p|
          p["producers"]["umath-external-model"]["configuration"]["upstream"]["use"] = "oracle"
        end
        expect_failure(dir, "configuration upstream")
      end
    end

    it "refuses a missing creator notice" do
      with_tree do |dir|
        File.write(File.join(dir, UnicodeExternal::NOTICE_PATH), "MIT License\n")
        expect_failure(dir, "lacks Copyright (c) 2019 Noah Doersing")
      end
    end

    it "refuses a generation with only one external producer" do
      with_tree do |dir|
        edit_yaml(provenance(dir)) do |p|
          p["producers"].delete("umath-external-model")
        end
        expect_failure(dir, "missing producer umath-external-model")
      end
    end

    it "refuses an executed-id list with a row missing" do
      with_tree do |dir|
        ids = File.join(dir, "executed.txt")
        File.write(ids, "unicode-external-001.raw\nunicode-external-001.raw\n")
        status, output = run_external(dir, "--cases", "4", "--generation",
                                      "1", "--executed", ids)
        expect(status).to eq(1), output
        expect(output).to include("7 expected rows not executed",
                                  "rows executed twice")
      end
    end
  end
end
