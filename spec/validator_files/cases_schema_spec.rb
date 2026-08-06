# frozen_string_literal: true

# What the cases schema rejects. Each broken fixture under spec/fixtures/
# carries exactly one defect; spec/fixtures/README.md names the check each
# one exists for. Runs with --no-integrity so that defect is the only failure.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "cases schema violations" do
  it "rejects a payload missing a required property" do
    expect(validation_of(fixture("cases-missing-required"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("is missing the required property `description`")
  end

  it "rejects a property the schema does not allow" do
    expect(validation_of(fixture("cases-extra-property"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/notes: is not an allowed property")
  end

  it "rejects a group name that is not a slug" do
    expect(validation_of(fixture("cases-bad-slug"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting('/group: "Bad_Slug" does not match')
  end

  it "rejects an empty cases list" do
    expect(validation_of(fixture("cases-empty-cases"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases: has 0 item(s), needs at least 1")
  end

  it "rejects duplicate targets" do
    expect(validation_of(fixture("cases-duplicate-targets"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting('/targets: has duplicate item(s): "asciimath"')
  end

  it "rejects an expected key that is not a target format" do
    expect(validation_of(fixture("cases-unknown-expected-key"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/expected/docx", "is not an allowed property name")
  end

  it "rejects a non-string input" do
    expect(validation_of(fixture("cases-nonstring-input"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/input: expected string, got integer")
  end

  it "rejects an empty input" do
    expect(validation_of(fixture("cases-empty-input"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/input: is shorter than 1 character")
  end

  it "rejects an id whose newline would slip past a line-anchored pattern" do
    expect(validation_of(fixture("cases-newline-in-id"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/id", "does not match")
  end

  # The two rejections below land at the CONTAINER pointer, not at the deep
  # defect: the anyOf closest-branch heuristic picks the branch with the
  # fewest complaints, and the shallow scalar branch always complains exactly
  # once. Pinned as observed behaviour; flagged in the suite's review notes.
  it "rejects a number in a parse tree, a scalar kind no tree has produced" do
    message = "/cases/0/parse_tree: matches none of the 3 anyOf alternatives"
    expect(validation_of(fixture("cases-number-in-parse-tree"),
                         "--no-integrity"))
      .to fail_validation
      # anyOf reports the container plus its closest branch
      .with_violations(2)
      .reporting(message)
  end

  it "rejects a model node that claims `class` but lacks `fields`" do
    message =
      "/cases/0/model/fields/value: matches none of the 3 anyOf alternatives"
    expect(validation_of(fixture("cases-malformed-node"), "--no-integrity"))
      .to fail_validation
      # anyOf reports the container plus its closest branch
      .with_violations(2)
      .reporting(message)
  end

  it "rejects a non-string mapping key" do
    expect(validation_of(fixture("cases-nonstring-key"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("has the non-string key 1")
  end

  it "escapes ~ and / when a property name lands in a JSON pointer" do
    expect(validation_of(fixture("pointer-escaped-property"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/we~1ird~0key: is not an allowed property")
  end
end
