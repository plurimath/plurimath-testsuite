# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../support/generator"

RSpec.describe CorpusGenerator, ".dump_yaml" do
  it "emits no anchors or aliases even when one object is referenced twice" do
    shared = { "k" => "v" }
    yaml = described_class.dump_yaml({ "a" => shared, "b" => shared })
    expect(yaml).not_to include("&")
    expect(yaml).not_to include("*")
    expect(YAML.safe_load(yaml, aliases: false))
      .to eq({ "a" => { "k" => "v" }, "b" => { "k" => "v" } })
  end

  it "strips the trailing space Psych leaves after a nil value" do
    yaml = described_class.dump_yaml({ "a" => nil, "b" => "x" })
    expect(yaml).to include("a:\n")
    trailing = yaml.lines.select { |line| line.chomp.match?(/[ \t]\z/) }
    expect(trailing).to be_empty,
                        "a line still ends in whitespace:\n#{yaml.inspect}"
  end

  it "is deterministic: the same data dumps to the same bytes" do
    data = { "z" => [1, 2, { "y" => "s" }], "a" => nil }
    # Two calls over the same input must dump identical bytes — the identical
    # expressions ARE the property under test.
    # rubocop:disable RSpec/IdenticalEqualityAssertion
    expect(described_class.dump_yaml(data))
      .to eq(described_class.dump_yaml(data))
    # rubocop:enable RSpec/IdenticalEqualityAssertion
  end

  it "round-trips the payload unchanged" do
    data = { "text" => "multi\nline", "n" => 3, "list" => %w[a b] }
    expect(YAML.safe_load(described_class.dump_yaml(data),
                          aliases: false)).to eq(data)
  end

  it "quotes numeric strings that YAML 1.2 would otherwise read as numbers" do
    strings = %w[0e0 1e21 1e-3 -1E+21 1.123_456_789 .123_456 0o17]
    data = { "outputs" => strings, "numbers" => [0, 17, 1.5] }
    yaml = described_class.dump_yaml(data)
    nodes = Psych.parse_stream(yaml).each.grep(Psych::Nodes::Scalar)
    outputs = nodes.select { |node| strings.include?(node.value) }

    expect(outputs.size).to eq(strings.size)
    expect(outputs).to all(have_attributes(plain: false, quoted: true))
    expect(YAML.safe_load(yaml, aliases: false)).to eq(data)
  end
end
