# frozen_string_literal: true

require "spec_helper"
require_relative "../scripts/lib/portable_yaml"

RSpec.describe PortableYaml do
  def load_dump(value)
    YAML.safe_load(described_class.dump(value), aliases: false)
  end

  it "quotes ambiguous strings while preserving actual numbers, booleans and null" do
    strings = %w[null NULL ~ on off yes no true false 012 0e0 1e21 1e-1000 .nan .inf 2026-10-21]
    payload = { "strings" => strings, "values" => [0, 12, 1.25, 1e21, true, false, nil] }
    yaml = described_class.dump(payload)
    expect(yaml.lines).to all(satisfy { |line| line.chomp == line.chomp.rstrip })
    expect(YAML.safe_load(yaml, aliases: false)).to eq(payload)
    strings.each { |string| expect(yaml).to include("- #{string.to_json}\n") }
    expect(load_dump(payload).fetch("values").map(&:class)).to eq(payload.fetch("values").map(&:class))
  end

  it "preserves multiline, Unicode, control characters, quotes and backslashes" do
    payload = { "text" => ["", "\n", "line one\nline two\n", "\t\r\0\a\b\e", "α🐟", '"quoted" \\ path', " leading ", "<<"] }
    expect(load_dump(payload)).to eq(payload)
  end

  it "quotes mapping keys and does not emit aliases for shared values" do
    shared = { "on" => "0e0" }
    payload = { "012" => [shared, shared], "1e21" => shared }
    yaml = described_class.dump(payload)
    expect(yaml).to include('"012":', '"1e21":', '"on": "0e0"')
    expect(YAML.safe_load(yaml, aliases: false)).to eq(payload)
    nodes = [Psych.parse_stream(yaml)]
    until nodes.empty?
      node = nodes.shift
      expect(node).not_to be_a(Psych::Nodes::Alias)
      expect(node.anchor).to be_nil if node.respond_to?(:anchor)
      nodes.concat(node.children || [])
    end
  end

  it "accepts JSON data nested beyond the default JSON depth" do
    payload = 120.times.reduce("1e21") { |value, _| [value] }
    expect(load_dump(payload)).to eq(payload)
  end

  it "rejects non-JSON keys, values, nonfinite numbers and cycles" do
    cycle = []
    cycle << cycle
    [{ symbol: "x" }, { "x" => :symbol }, { "x" => Object.new },
     { "x" => Float::INFINITY }, { "x" => Float::NAN }, cycle].each do |payload|
      expect { described_class.dump(payload) }.to raise_error(PortableYaml::Error)
    end
  end

  it "leaves ordinary Psych dumping unchanged" do
    before = YAML.dump({ "word" => "ordinary" })
    described_class.dump({ "word" => "ordinary" })
    expect(YAML.dump({ "word" => "ordinary" })).to eq(before)
  end
end
