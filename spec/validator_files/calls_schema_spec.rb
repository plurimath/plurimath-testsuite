# frozen_string_literal: true

# What calls/1's cross-field checks reject. Each broken fixture under
# spec/fixtures/ carries exactly one defect. Runs with --no-integrity so that
# defect is the only failure.
#
# The healthy case comes first on purpose: a negative test whose fixture was
# broken for some other reason proves nothing, and every fixture below is
# that same payload with one thing changed.
#
# `calls/1` composes the same four checks `cases/2` does, except it needs
# `rejection_format_errors` rather than `input_format_errors` for the format
# check, because its schema's middle segment is a KIND (`calls`), not an
# input format — the same situation `rejections/1` is in. These four are
# `call_cross_checks` observed from the outside, the way `rejections_schema_
# spec.rb` and `cases2_schema_spec.rb` observe their own kinds' checks.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "calls schema" do
  it "accepts a healthy payload, so the rest fail only on their defect" do
    expect(validation_of(fixture("calls-healthy"),
                         "--no-integrity")).to pass_validation
  end

  it "rejects a group that does not match the file name" do
    expect(validation_of(fixture("calls-wrong-group"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("is \"wrong\", but the file is named number-formatting.yaml")
  end

  it "rejects a group filed in the wrong directory" do
    expect(validation_of(fixture("calls-format-vs-directory"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting('/input_format: is "asciimath", but the file sits in mathml/')
  end

  it "rejects a case that switches input format mid-group" do
    expect(validation_of(fixture("calls-case-format-drift"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/input_format",
                 "a case does not switch formats mid-group")
  end

  it "rejects two cases sharing an id" do
    expect(validation_of(fixture("calls-duplicate-id"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting('reuses "number-formatter-de-style-grouping"')
  end

  it "rejects an expectation outside the group's targets" do
    expect(validation_of(fixture("calls-expected-outside-targets"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/expected/latex",
                 "which is not one of the group's targets (asciimath)")
  end

  it "rejects a target no expectation covers" do
    expect(validation_of(fixture("calls-target-missing-expectation"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/expected", "carries no expectation for `latex`")
  end
end
