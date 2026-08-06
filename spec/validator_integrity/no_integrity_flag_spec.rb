# frozen_string_literal: true

# --no-integrity skips exactly the provenance checksum and coverage checks,
# nothing more.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "--no-integrity" do
  it "skips the digest comparison" do
    expect(validation_of(fixture("integrity-sha-mismatch"), "--no-integrity"))
      .to pass_validation
  end

  it "skips the provenance-presence requirement" do
    expect(validation_of(fixture("integrity-missing-provenance"),
                         "--no-integrity"))
      .to pass_validation
  end

  it "still validates every file against its schema" do
    expect(validation_of(fixture("cases-missing-required"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("is missing the required property `description`")
  end
end
