# frozen_string_literal: true

# `targets` and every case's `expected` keys are the same set: a key outside
# `targets` is an expectation the group never declared, and a target with no
# key is a promise the case does not keep.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner,
               "targets and expected agree in both directions" do
  it "rejects an expectation outside the group's targets" do
    expect(validation_of(fixture("expected-outside-targets"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/expected/latex",
                 "which is not one of the group's targets (asciimath)")
  end

  it "rejects a target no expectation covers" do
    expect(validation_of(fixture("target-missing-expectation"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/expected", "carries no expectation for `latex`")
  end
end
