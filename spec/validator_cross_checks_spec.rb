# frozen_string_literal: true

# The constraints JSON Schema cannot express: relations between two fields,
# between a field and the file it sits in, and between sibling entries.
# scripts/validate.rb promises each of these where the schemas only describe
# them; every promise gets a broken fixture here.

require_relative "spec_helper"

describe "group and file name" do
  it "rejects a group that is not the file's stem" do
    assert_rejects fixture("group-vs-filename"), "--no-integrity",
                   violations: 1, message: ['/group: is "numbers", but the file is named misnamed.yaml']
  end
end

describe "input_format agreement (one fact, four spellings)" do
  it "rejects an input_format that disagrees with the schema declaration" do
    assert_rejects fixture("format-vs-schema-segment"), "--no-integrity",
                   violations: 1, message: ["/input_format", "whose middle segment is the input format"]
  end

  it "rejects a group filed in the wrong directory" do
    assert_rejects fixture("format-vs-directory"), "--no-integrity",
                   violations: 1, message: ['/input_format: is "asciimath", but the file sits in mathml/']
  end

  it "rejects a case that switches format mid-group" do
    assert_rejects fixture("format-vs-case"), "--no-integrity",
                   violations: 1, message: ["/cases/0/input_format",
                             "a case does not switch formats mid-group"]
  end
end

describe "case ids" do
  it "rejects an id another case already uses" do
    assert_rejects fixture("duplicate-case-ids"), "--no-integrity",
                   violations: 1, message: ['/cases/1/id: reuses "number-integer", which case 0 already uses']
  end
end

describe "targets and expected agree in both directions" do
  it "rejects an expectation outside the group's targets" do
    assert_rejects fixture("expected-outside-targets"), "--no-integrity",
                   violations: 1, message: ["/cases/0/expected/latex",
                             "which is not one of the group's targets (asciimath)"]
  end

  it "rejects a target no expectation covers" do
    assert_rejects fixture("target-missing-expectation"), "--no-integrity",
                   violations: 1, message: ["/cases/0/expected",
                             "carries no expectation for `latex`"]
  end
end

describe "provenance payload ordering" do
  it "rejects a payloads list that is not sorted by path" do
    assert_rejects fixture("payloads-unsorted"), "--no-integrity",
                   violations: 1, message: ["/payloads/1/path",
                             "records asciimath/aaa.yaml after asciimath/zzz.yaml"]
  end
end
