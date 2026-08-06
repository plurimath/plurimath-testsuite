# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../support/generator"

RSpec.describe CorpusGenerator, ".usage" do
  it "reads its own file header as the help text" do
    expect(described_class.usage)
      .to include("Usage, from the plurimath-testsuite repository root")
  end
end
