# frozen_string_literal: true

# Provenance and the files on disk must be the same set, entry for entry,
# digest for digest.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "digests and coverage" do
  it "rejects a payload whose sha256 does not match" do
    expect(validation_of(fixture("integrity-sha-mismatch")))
      .to fail_validation.with_violations(1)
      .reporting("/payloads/0/sha256", "but that file hashes to")
  end

  it "rejects a payload whose byte count does not match" do
    expect(validation_of(fixture("integrity-bytes-mismatch")))
      .to fail_validation.with_violations(1)
      .reporting("/payloads/0/bytes: records 999999 bytes", "but that file is")
  end

  it "rejects a payload on disk that provenance never mentions" do
    expect(validation_of(fixture("integrity-unrecorded-payload")))
      .to fail_validation.with_violations(1)
      .reporting("extra.yaml", "is not recorded in")
  end

  it "rejects a recorded payload that is not on disk" do
    expect(validation_of(fixture("integrity-ghost-payload")))
      .to fail_validation.with_violations(1)
      .reporting("records asciimath/ghost.yaml, which is not a payload in")
  end

  it "rejects a payload recorded twice" do
    expect(validation_of(fixture("integrity-duplicate-entry")))
      .to fail_validation.with_violations(1)
      .reporting("records asciimath/numbers.yaml a second time")
  end
end
