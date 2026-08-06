# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../support/generator"

RSpec.describe CorpusGenerator, ".parse_lockfile" do
  let(:lock) do
    described_class.parse_lockfile(File.join(SpecHelpers::FIXTURES,
                                             "lockfiles", "sample.lock"))
  end

  it "reads every source section by kind" do
    expect(lock[:sources].map { |s| s["kind"] }).to eq(%w[path git gem])
  end

  it "resolves every spec, including after a bare `specs:` line" do
    # The regression this pins: splitting on ": " instead of ":" missed the
    # bare `specs:` key, and zero dependencies were parsed.
    expect(lock[:specs].keys.sort).to eq(%w[dep nokogiri parslet plurimath])
  end

  it "records name, version, platform and source per spec" do
    parslet = lock[:specs]["parslet"]
    expect(parslet["version"]).to eq("2.0.0")
    expect(parslet["platform"]).to eq("ruby")
    expect(parslet["source"]["kind"]).to eq("gem")
    expect(parslet["source"]["remote"]).to eq("https://rubygems.org/")
  end

  it "splits a platform suffix off the version" do
    nokogiri = lock[:specs]["nokogiri"]
    expect(nokogiri["version"]).to eq("1.16.5")
    expect(nokogiri["platform"]).to eq("x86_64-linux")
  end

  it "keeps a git source's revision and a path source's remote" do
    expect(lock[:specs]["dep"]["source"]["revision"]).to eq("a" * 40)
    expect(lock[:specs]["plurimath"]["source"]["remote"]).to eq(".")
  end

  it "does not record a sub-dependency line as a resolved version" do
    # `parslet (~> 2.0)` sits under plurimath at deeper indentation; only the
    # GEM section's `parslet (2.0.0)` may win.
    expect(lock[:specs]["parslet"]["version"]).not_to eq("~> 2.0")
  end

  it "collects platforms only from PLATFORMS, sorted" do
    # The regression this pins: every indented line of any unrecognised
    # section (DEPENDENCIES, CHECKSUMS, ...) was collected as a platform.
    expect(lock[:platforms]).to eq(%w[ruby x86_64-linux])
  end

  it "reads the BUNDLED WITH version" do
    expect(lock[:bundled_with]).to eq("2.6.9")
  end
end
