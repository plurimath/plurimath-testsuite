# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "healthy corpora" do
  it "passes the minimal healthy corpus, integrity included" do
    result = validation_of(fixture("healthy-minimal"))
    expect(result).to pass_validation
    expect(result.output)
      .to include("2 files: 1 payload (1 case), 1 provenance — all valid")
  end

  it "still passes when a tmpdir copy is re-validated in place" do
    with_fixture_copy("healthy-minimal") do |dir|
      expect(validation_of(dir)).to pass_validation
    end
  end

  it "fails the same copy the moment one payload byte changes" do
    with_fixture_copy("healthy-minimal") do |dir|
      payload = File.join(dir, "asciimath", "numbers.yaml")
      File.binwrite(payload,
                    File.binread(payload).sub('input: "2"', 'input: "3"'))
      expect(validation_of(dir))
        .to fail_validation.reporting("/payloads/0/sha256",
                                      "but that file hashes to")
    end
  end
end
