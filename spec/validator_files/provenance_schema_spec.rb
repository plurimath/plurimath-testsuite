# frozen_string_literal: true

# What the provenance schema rejects — chiefly the `committable` relation:
# committable is true exactly when there are no warnings to disclaim.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "provenance schema violations" do
  it "rejects committable: true alongside warnings" do
    expect(validation_of(fixture("prov-committable-with-warnings"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/committable: expected false, got true")
  end

  it "rejects committable: false with no warnings to justify it" do
    expect(validation_of(fixture("prov-uncommittable-without-warnings"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/committable: expected true, got false")
  end

  it "rejects committable: true over a dirty oracle checkout" do
    expect(validation_of(fixture("prov-committable-dirty-oracle"),
                         "--no-integrity"))
      .to fail_validation
      # the relation reports clean and dirty_paths together
      .with_violations(2)
      .reporting("/oracle/clean: expected true, got false")
  end

  it "rejects clean: true alongside dirty_paths, and reports it once" do
    message =
      "/generator/repository/dirty_paths: has 1 item(s), allows at most 0"
    result = validation_of(fixture("prov-clean-with-dirty-paths"),
                           "--no-integrity")
    expect(result).to fail_validation.with_violations(1).reporting(message)
    expect(result.output.scan("allows at most 0").length)
      .to eq(1), "two rules reached the same complaint; " \
                 "the report must dedupe it"
  end

  it "rejects clean: false with no dirty path named" do
    expect(validation_of(fixture("prov-dirty-without-paths"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/oracle/dirty_paths: has 0 item(s), needs at least 1")
  end

  it "rejects a git-sourced dependency without its revision" do
    expect(validation_of(fixture("prov-git-without-revision"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/direct_runtime/unitsml",
                 "is missing the required property `revision`")
  end

  it "rejects a malformed sha256" do
    expect(validation_of(fixture("prov-bad-sha256"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/payloads/0/sha256", "does not match")
  end

  it "rejects a payload path that escapes the corpus root" do
    expect(validation_of(fixture("prov-path-escape"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/payloads/0/path", "does not match")
  end

  it "accepts a fully-resolved provenance: git revision, platform build, " \
     "null bundler" do
    expect(validation_of(fixture("healthy-git-revision"), "--no-integrity"))
      .to pass_validation
  end
end
