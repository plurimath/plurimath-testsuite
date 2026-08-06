# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../support/generator"

RSpec.describe CorpusGenerator, ".unshare" do
  it "rebuilds the structure so no two nodes are the same object" do
    shared = { "k" => "v" }
    rebuilt = described_class.unshare([shared, shared])
    expect(rebuilt).to eq([shared, shared])
    expect(rebuilt[0]).not_to equal(rebuilt[1]),
                              "the two entries are still one object"
  end
end
