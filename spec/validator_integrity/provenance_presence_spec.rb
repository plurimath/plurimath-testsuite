# frozen_string_literal: true

# The integrity layer needs exactly one provenance document, at the corpus
# root, before there is anything to check digests against.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "provenance presence" do
  it "rejects a corpus with payloads but no provenance" do
    expect(validation_of(fixture("integrity-missing-provenance")))
      .to fail_validation.with_violations(1)
      .reporting("provenance.yaml",
                 "is missing; without it every payload here is unattributed")
  end

  it "rejects a corpus where two files declare the provenance schema" do
    expect(validation_of(fixture("integrity-two-provenance")))
      .to fail_validation.with_violations(1)
      .reporting("the corpus has one provenance document, but 2 declare it")
  end

  it "rejects a provenance document that is not at the corpus root" do
    expect(validation_of(fixture("integrity-provenance-not-at-root")))
      .to fail_validation.with_violations(1)
      .reporting("must be the corpus root's")
  end
end
