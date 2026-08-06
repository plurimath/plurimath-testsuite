# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../support/generator"

RSpec.describe CorpusGenerator, ".direct_runtime_value" do
  let(:lock) do
    described_class.parse_lockfile(File.join(SpecHelpers::FIXTURES,
                                             "lockfiles", "sample.lock"))
  end

  it "collapses a plainly-resolved gem to its bare version" do
    value = described_class.direct_runtime_value(lock[:specs]["parslet"])
    expect(value).to eq("2.0.0")
  end

  it "keeps the full resolution for a git source, revision included" do
    value = described_class.direct_runtime_value(lock[:specs]["dep"])
    expect(value["source_kind"]).to eq("git")
    expect(value["source"]).to eq("https://github.com/example/dep.git")
    expect(value["revision"]).to eq("a" * 40)
  end

  it "keeps the full resolution for a platform-specific build, " \
     "without a revision key" do
    value = described_class.direct_runtime_value(lock[:specs]["nokogiri"])
    expect(value["platform"]).to eq("x86_64-linux")
    expect(value).not_to have_key("revision")
  end
end
