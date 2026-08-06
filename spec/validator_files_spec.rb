# frozen_string_literal: true

# File-level behaviour of scripts/validate.rb: what may exist in a corpus,
# how a payload is read, how it selects its schema, and what the per-kind
# schemas reject. Each broken fixture under spec/fixtures/ carries exactly
# one defect; spec/fixtures/README.md names the check each one exists for.
# These run with --no-integrity so the one defect is the only failure.

require_relative "spec_helper"

RSpec.describe "corpus layout" do
  it "rejects a stray file at the corpus root" do
    assert_rejects fixture("stray-root-file"), "--no-integrity",
                   violations: 1, message: ["NOTES.txt", "is not a file the corpus layout allows"]
  end

  it "rejects a payload with a .yml extension" do
    assert_rejects fixture("stray-wrong-extension"), "--no-integrity",
                   violations: 1, message: ["extra.yml", "is not a file the corpus layout allows"]
  end

  it "rejects a dotfile, which the old glob never saw" do
    assert_rejects fixture("stray-dotfile"), "--no-integrity",
                   violations: 1, message: [".hidden", "is not a file the corpus layout allows"]
  end

  it "rejects a payload nested deeper than <input-format>/<group>.yaml" do
    assert_rejects fixture("stray-nested-dir"), "--no-integrity",
                   violations: 1, message: ["deep/sample.yaml", "is not a file the corpus layout allows"]
  end

  it "rejects an uppercase file name" do
    assert_rejects fixture("stray-uppercase"), "--no-integrity",
                   violations: 1, message: ["Sample.yaml", "is not a file the corpus layout allows"]
  end

  it "rejects a file symlink even when its name is allowed" do
    with_fixture_copy("healthy-minimal") do |dir|
      # The link's target is a file inside the copied fixture: what is being
      # tested is the link, and an OS file like /etc/hostname is not present
      # on every platform the suite runs on.
      File.symlink(File.join(dir, "provenance.yaml"),
                   File.join(dir, "asciimath", "link.yaml"))
      expect { run_validator(dir) }.to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("the corpus may not contain symlinks")
        expect(error.message).to include("link.yaml")
      }
    end
  end

  it "rejects a directory symlink before the directory filter can follow it" do
    with_fixture_copy("healthy-minimal") do |dir|
      File.symlink(File.join(fixture("healthy-minimal"), "asciimath"),
                   File.join(dir, "latex"))
      expect { run_validator(dir) }.to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("the corpus may not contain symlinks")
      }
    end
  end

  it "rejects a dangling symlink" do
    with_fixture_copy("healthy-minimal") do |dir|
      File.symlink("/nonexistent/target", File.join(dir, "asciimath", "gone.yaml"))
      expect { run_validator(dir) }.to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("the corpus may not contain symlinks")
      }
    end
  end
end

RSpec.describe "payload reading" do
  it "rejects YAML anchors and aliases as non-portable" do
    assert_rejects fixture("yaml-anchor-alias"), "--no-integrity",
                   violations: 1, message: "is not portable YAML"
  end

  it "reports a YAML syntax error as a failure, not a crash" do
    assert_rejects fixture("yaml-syntax-error"), "--no-integrity",
                   violations: 1, message: "is not portable YAML"
  end

  it "rejects a payload that is not a mapping" do
    assert_rejects fixture("payload-not-a-mapping"), "--no-integrity",
                   violations: 1, message: "a payload must be a mapping, got Array"
  end

  # 20k levels: roughly double what overflows the VM stack today, and an
  # order of magnitude cheaper to raise through than a larger constant.
  it "rejects a file too deeply nested to read" do
    deep = "#{'[' * 20_000}#{']' * 20_000}\n"
    with_corpus("asciimath/deep.yaml" => deep) do |dir|
      assert_rejects dir, "--no-integrity", message: "nests too deeply"
    end
  end
end

RSpec.describe "non-JSON numbers" do
  it "rejects .nan, .inf, +.inf and -.inf, each at its pointer" do
    out = assert_rejects fixture("nonfinite-numbers"), "--no-integrity",
                         # the fixture carries all four spellings on purpose
                         violations: 4, message: "which JSON cannot represent"
    expect(out).to include("/nan_value: is NaN")
    expect(out).to include("/inf_value: is Infinity")
    expect(out).to include("/plus_inf_value: is Infinity")
    expect(out).to include("/nested/values/0: is -Infinity")
  end

  it "rejects them before schema evaluation, so a NaN never reaches a type check" do
    out = assert_rejects fixture("nonfinite-numbers"), "--no-integrity",
                         # the fixture carries all four spellings on purpose
                         violations: 4, message: "is NaN"
    expect(out).not_to include("missing the required property"),
                       "schema evaluation ran on a payload holding a NaN"
  end

  it "escapes the pointer token even for a non-string key" do
    out = assert_rejects fixture("nonfinite-under-nonstring-key"), "--no-integrity",
                         violations: 1, message: "is NaN"
    expect(out).to include('/["a~1b"]: is NaN')
  end
end

RSpec.describe "schema dispatch" do
  it "rejects a payload with no schema key" do
    assert_rejects fixture("schema-key-missing"), "--no-integrity",
                   violations: 1, message: "/schema: missing; every payload declares the schema it follows"
  end

  it "rejects a schema key that is not a string, naming what arrived" do
    assert_rejects fixture("schema-key-nonstring"), "--no-integrity",
                   violations: 1, message: "must name a schema as a string, got integer 5"
  end

  it "rejects a declaration no schema claims" do
    assert_rejects fixture("schema-unclaimed"), "--no-integrity",
                   violations: 1, message: 'no schema in'
  end

  it "rejects a declaration claimed by more than one schema" do
    assert_rejects fixture("schema-ambiguous"), "--no-integrity",
                   schema_dir: fixture("schemas/ambiguous"),
                   violations: 1, message: "is claimed by 2 schemas"
  end

  it "refuses to load two schemas claiming the same declaration" do
    expect do
      run_validator(fixture("healthy-minimal"),
                    schema_dir: fixture("schemas/duplicate-claim"))
    end.to raise_error(Testsuite::Failure) { |error|
      expect(error.message).to include("two schemas claim plurimath-corpus/asciimath/1")
    }
  end

  it "refuses a schema file that is not valid JSON" do
    expect do
      run_validator(fixture("healthy-minimal"),
                    schema_dir: fixture("schemas/invalid-json"))
    end.to raise_error(Testsuite::Failure) { |error|
      expect(error.message).to include("invalid JSON")
    }
  end

  it "refuses an empty schema directory" do
    Dir.mktmpdir do |empty|
      expect do
        run_validator(fixture("healthy-minimal"), schema_dir: empty)
      end.to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("no schemas in")
      }
    end
  end
end

RSpec.describe "cases schema violations" do
  it "rejects a payload missing a required property" do
    assert_rejects fixture("cases-missing-required"), "--no-integrity",
                   violations: 1, message: "is missing the required property `description`"
  end

  it "rejects a property the schema does not allow" do
    assert_rejects fixture("cases-extra-property"), "--no-integrity",
                   violations: 1, message: "/notes: is not an allowed property"
  end

  it "rejects a group name that is not a slug" do
    assert_rejects fixture("cases-bad-slug"), "--no-integrity",
                   violations: 1, message: ['/group: "Bad_Slug" does not match']
  end

  it "rejects an empty cases list" do
    assert_rejects fixture("cases-empty-cases"), "--no-integrity",
                   violations: 1, message: "/cases: has 0 item(s), needs at least 1"
  end

  it "rejects duplicate targets" do
    assert_rejects fixture("cases-duplicate-targets"), "--no-integrity",
                   violations: 1, message: '/targets: has duplicate item(s): "asciimath"'
  end

  it "rejects an expected key that is not a target format" do
    assert_rejects fixture("cases-unknown-expected-key"), "--no-integrity",
                   violations: 1, message: ["/cases/0/expected/docx", "is not an allowed property name"]
  end

  it "rejects a non-string input" do
    assert_rejects fixture("cases-nonstring-input"), "--no-integrity",
                   violations: 1, message: "/cases/0/input: expected string, got integer"
  end

  it "rejects an empty input" do
    assert_rejects fixture("cases-empty-input"), "--no-integrity",
                   violations: 1, message: "/cases/0/input: is shorter than 1 character"
  end

  it "rejects an id whose newline would slip past a line-anchored pattern" do
    assert_rejects fixture("cases-newline-in-id"), "--no-integrity",
                   violations: 1, message: ["/cases/0/id", "does not match"]
  end

  # The two rejections below land at the CONTAINER pointer, not at the deep
  # defect: the anyOf closest-branch heuristic picks the branch with the
  # fewest complaints, and the shallow scalar branch always complains exactly
  # once. Pinned as observed behaviour; flagged in the suite's review notes.
  it "rejects a number in a parse tree, a scalar kind no tree has produced" do
    assert_rejects fixture("cases-number-in-parse-tree"), "--no-integrity",
                   # anyOf reports the container plus its closest branch
                   violations: 2, message: ["/cases/0/parse_tree: matches none of the 3 anyOf alternatives"]
  end

  it "rejects a model node that claims `class` but lacks `fields`" do
    assert_rejects fixture("cases-malformed-node"), "--no-integrity",
                   # anyOf reports the container plus its closest branch
                   violations: 2, message: ["/cases/0/model/fields/value: matches none of the 3 anyOf alternatives"]
  end

  it "rejects a non-string mapping key" do
    assert_rejects fixture("cases-nonstring-key"), "--no-integrity",
                   violations: 1, message: "has the non-string key 1"
  end

  it "escapes ~ and / when a property name lands in a JSON pointer" do
    assert_rejects fixture("pointer-escaped-property"), "--no-integrity",
                   violations: 1, message: "/we~1ird~0key: is not an allowed property"
  end
end

RSpec.describe "provenance schema violations" do
  it "rejects committable: true alongside warnings" do
    assert_rejects fixture("prov-committable-with-warnings"), "--no-integrity",
                   violations: 1, message: "/committable: expected false, got true"
  end

  it "rejects committable: false with no warnings to justify it" do
    assert_rejects fixture("prov-uncommittable-without-warnings"), "--no-integrity",
                   violations: 1, message: "/committable: expected true, got false"
  end

  it "rejects committable: true over a dirty oracle checkout" do
    assert_rejects fixture("prov-committable-dirty-oracle"), "--no-integrity",
                   # the relation reports clean and dirty_paths together
                   violations: 2, message: "/oracle/clean: expected true, got false"
  end

  it "rejects clean: true alongside dirty_paths, and reports it once" do
    out = assert_rejects fixture("prov-clean-with-dirty-paths"), "--no-integrity",
                         violations: 1, message: "/generator/repository/dirty_paths: has 1 item(s), allows at most 0"
    expect(out.scan("allows at most 0").length).to eq(1),
      "two rules reached the same complaint; the report must dedupe it"
  end

  it "rejects clean: false with no dirty path named" do
    assert_rejects fixture("prov-dirty-without-paths"), "--no-integrity",
                   violations: 1, message: "/oracle/dirty_paths: has 0 item(s), needs at least 1"
  end

  it "rejects a git-sourced dependency without its revision" do
    assert_rejects fixture("prov-git-without-revision"), "--no-integrity",
                   violations: 1, message: ["/direct_runtime/unitsml",
                             "is missing the required property `revision`"]
  end

  it "rejects a malformed sha256" do
    assert_rejects fixture("prov-bad-sha256"), "--no-integrity",
                   violations: 1, message: ["/payloads/0/sha256", "does not match"]
  end

  it "rejects a payload path that escapes the corpus root" do
    assert_rejects fixture("prov-path-escape"), "--no-integrity",
                   violations: 1, message: ["/payloads/0/path", "does not match"]
  end

  it "accepts a fully-resolved provenance: git revision, platform build, null bundler" do
    assert_accepts fixture("healthy-git-revision"), "--no-integrity"
  end
end
