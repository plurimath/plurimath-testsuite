# frozen_string_literal: true

# What may exist in a corpus: provenance.yaml at the root, payloads at
# <input-format>/<group>.yaml, and nothing else — symlinks never.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "corpus layout" do
  it "rejects a stray file at the corpus root" do
    expect(validation_of(fixture("stray-root-file"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("NOTES.txt", "is not a file the corpus layout allows")
  end

  it "rejects a payload with a .yml extension" do
    expect(validation_of(fixture("stray-wrong-extension"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("extra.yml", "is not a file the corpus layout allows")
  end

  it "rejects a dotfile, which the old glob never saw" do
    expect(validation_of(fixture("stray-dotfile"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting(".hidden", "is not a file the corpus layout allows")
  end

  it "rejects a payload nested deeper than <input-format>/<group>.yaml" do
    expect(validation_of(fixture("stray-nested-dir"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("deep/sample.yaml", "is not a file the corpus layout allows")
  end

  it "rejects an uppercase file name" do
    expect(validation_of(fixture("stray-uppercase"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("Sample.yaml", "is not a file the corpus layout allows")
  end

  it "rejects a file symlink even when its name is allowed" do
    with_fixture_copy("healthy-minimal") do |dir|
      # The link's target is a file inside the copied fixture: what is being
      # tested is the link, and an OS file like /etc/hostname is not present
      # on every platform the suite runs on.
      File.symlink(File.join(dir, "provenance.yaml"),
                   File.join(dir, "asciimath", "link.yaml"))
      expect { validation_of(dir) }.to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("the corpus may not contain symlinks")
        expect(error.message).to include("link.yaml")
      }
    end
  end

  it "rejects a directory symlink before the directory filter can follow it" do
    with_fixture_copy("healthy-minimal") do |dir|
      File.symlink(File.join(fixture("healthy-minimal"), "asciimath"),
                   File.join(dir, "latex"))
      expect { validation_of(dir) }.to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("the corpus may not contain symlinks")
      }
    end
  end

  it "rejects a dangling symlink" do
    with_fixture_copy("healthy-minimal") do |dir|
      File.symlink("/nonexistent/target",
                   File.join(dir, "asciimath", "gone.yaml"))
      expect { validation_of(dir) }.to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("the corpus may not contain symlinks")
      }
    end
  end
end
