# frozen_string_literal: true

# A run that finds nothing to validate fails unless --allow-empty says that
# is expected — and --allow-empty excuses emptiness only, never broken files.

require_relative "../spec_helper"

RSpec.describe Testsuite::CLI, "empty and missing corpora" do
  it "exits 2 when the corpus directory does not exist" do
    status, _out, err = run_validator_process("/nonexistent/corpus")
    expect(status).to eq(2)
    expect(err).to include("no corpus directory at")
  end

  it "exits 0 for a missing corpus directory under --allow-empty" do
    status, out, = run_validator_process("/nonexistent/corpus", "--allow-empty")
    expect(status).to eq(0)
    expect(out).to include("schemas checked, no payloads validated")
  end

  it "exits 1 when the corpus directory exists but holds nothing" do
    Dir.mktmpdir do |empty|
      status, out, = run_validator_process(empty)
      expect(status).to eq(1)
      expect(out).to include("A validator that validates nothing is not a pass")
    end
  end

  it "exits 0 for an existing empty corpus under --allow-empty" do
    Dir.mktmpdir do |empty|
      status, out, = run_validator_process(empty, "--allow-empty")
      expect(status).to eq(0)
      expect(out).to include("(--allow-empty)")
    end
  end

  it "does not let --allow-empty excuse a corpus that has broken files" do
    status, _out, = run_validator_process(fixture("cases-missing-required"),
                                          "--allow-empty", "--no-integrity")
    expect(status).to eq(1)
  end
end
