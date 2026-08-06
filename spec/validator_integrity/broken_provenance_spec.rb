# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner,
               "integrity and the provenance's own validity" do
  it "does not run integrity against a provenance that failed its schema" do
    result = validation_of(fixture("integrity-skips-broken-provenance"))
    expect(result).to fail_validation.with_violations(1)
      .reporting("/committable: expected false, got true")
    expect(result.output).not_to include("is not recorded"),
                                 "integrity ran against a provenance there " \
                                 "is no reason to trust"
  end
end
