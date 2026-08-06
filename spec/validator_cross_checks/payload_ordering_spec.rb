# frozen_string_literal: true

# The provenance says `payloads` is sorted by path, and a diff of the corpus
# is only readable while it stays that way.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "provenance payload ordering" do
  it "rejects a payloads list that is not sorted by path" do
    expect(validation_of(fixture("payloads-unsorted"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/payloads/1/path",
                 "records asciimath/aaa.yaml after asciimath/zzz.yaml")
  end
end
