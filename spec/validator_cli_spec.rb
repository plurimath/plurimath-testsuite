# frozen_string_literal: true

# The process contract, exercised through a real `ruby scripts/validate.rb`
# subprocess: exit 0 when every file is valid, 1 on any violation, 2 on a
# usage or schema error — plus the option parser and the empty-corpus rules.
# The first spec is CI's own invocation, so the real corpus is the healthy
# case here; the broken fixtures never duplicate it.

require_relative "spec_helper"

RSpec.describe "validate.rb as a process" do
  it "exits 0 on the real corpus, invoked exactly as CI invokes it" do
    status, out, = run_validator_process
    expect(status).to eq(0), out
    # Every count is optionally plural: the validator prints `1 file`,
    # `1 payload`, `1 case` — the corpus growing or shrinking through 1 of
    # anything must not fail CI's own invocation.
    expect(out).to match(/\d+ files?: \d+ payloads? \(\d+ cases?\), 1 provenance — all valid/)
  end

  it "exits 1 on a corpus violation" do
    status, out, = run_validator_process(fixture("cases-missing-required"),
                                         "--no-integrity")
    expect(status).to eq(1)
    expect(out).to include("FAIL")
  end

  it "exits 2 on an unknown option, with the usage text" do
    status, _out, err = run_validator_process("--bogus")
    expect(status).to eq(2)
    expect(err).to include("unknown option --bogus")
    expect(err).to include("usage: validate.rb")
  end

  it "exits 2 when --schema is given no directory" do
    status, _out, err = run_validator_process(fixture("healthy-minimal"), "--schema")
    expect(status).to eq(2)
    expect(err).to include("--schema needs a directory")
  end

  it "accepts the --schema=DIR spelling" do
    status, out, = run_validator_process(fixture("healthy-minimal"),
                                         "--schema=#{SpecHelpers::SCHEMA_DIR}")
    expect(status).to eq(0), out
  end

  it "exits 2 on more than one corpus root" do
    status, _out, err = run_validator_process("one", "two")
    expect(status).to eq(2)
    expect(err).to include("expected at most one corpus root, got 2")
  end

  it "exits 2 when the schema directory holds no schemas" do
    Dir.mktmpdir do |empty|
      status, _out, err = run_validator_process(fixture("healthy-minimal"),
                                                "--schema", empty)
      expect(status).to eq(2)
      expect(err).to include("no schemas in")
    end
  end

  it "fails loudly on a symlink in the corpus" do
    # Deliberately NOT pinned to a specific exit code. Today a symlink raises
    # `Failure` (exit 2) while a stray file reports per-file (exit 1) — a
    # recorded inconsistency and an open decision, not a contract. Asserting 2
    # would make this spec fight the fix if 1 is ever chosen. What IS
    # contract: the run fails, and the message names the problem.
    with_fixture_copy("healthy-minimal") do |dir|
      # The link's target is a file inside the copied fixture: what is being
      # tested is the link, and an OS file like /etc/hostname is not present
      # on every platform the suite runs on.
      File.symlink(File.join(dir, "provenance.yaml"),
                   File.join(dir, "asciimath", "link.yaml"))
      status, _out, err = run_validator_process(dir)
      expect(status).not_to eq(0), "a symlinked corpus must not validate"
      expect(err).to include("the corpus may not contain symlinks")
    end
  end

  it "prints usage and exits 0 on --help" do
    status, out, = run_validator_process("--help")
    expect(status).to eq(0)
    expect(out).to include("usage: validate.rb")
    expect(out).to include("Exits 0 when every file is valid")
  end
end

RSpec.describe "empty and missing corpora" do
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
