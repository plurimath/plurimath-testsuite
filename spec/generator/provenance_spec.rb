# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../support/generator"

RSpec.describe CorpusGenerator, "provenance assembly" do
  # One probe writes the document, reads it back, and checks ordering, digest
  # and size in a single filesystem round-trip — deliberately not split.
  # rubocop:disable RSpec/ExampleLength
  it "writes payload entries sorted by path with computed digests" do
    Dir.mktmpdir do |out|
      payloads = [
        [File.join(out, "asciimath", "zzz.yaml"), "content-z"],
        [File.join(out, "asciimath", "aaa.yaml"), "content-a"],
      ]
      path = described_class.write_provenance(out, { "schema" => "s" },
                                              payloads)

      expect(path).to eq(File.join(out, "provenance.yaml"))
      text = File.read(path)
      expect(text).to start_with("# Provenance shared by every payload"),
                      "missing the provenance header"

      document = YAML.safe_load(text, aliases: false)
      expect(document["payloads"].map { |entry| entry["path"] })
        .to eq(["asciimath/aaa.yaml", "asciimath/zzz.yaml"])
      expect(document["payloads"][0]["sha256"])
        .to eq(Digest::SHA256.hexdigest("content-a"))
      expect(document["payloads"][0]["bytes"]).to eq("content-a".bytesize)
    end
  end
  # rubocop:enable RSpec/ExampleLength

  it "computes sha256 as the plain hex digest" do
    expect(described_class.sha256("abc"))
      .to eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  end

  it "makes paths relative to a root, leaving outsiders untouched" do
    expect(described_class.relative("/a/b/c", "/a")).to eq("b/c")
    expect(described_class.relative("/other/file", "/a")).to eq("/other/file")
  end

  it "stamps every payload as generated, with the provenance location" do
    header =
      described_class.payload_header("AsciiMath conformance cases: numbers.")
    expect(header).to include("Do not edit")
    expect(header).to include("corpus/provenance.yaml")
  end

  it "carries the kind it was given, not a fixed label" do
    # The kind is the part of the header that varies per file, so it is the
    # part a gutted `payload_header` corrupts.
    numbers =
      described_class.payload_header("AsciiMath conformance cases: numbers.")
    frac =
      described_class.payload_header("AsciiMath conformance cases: frac.")
    expect(numbers).to include("# AsciiMath conformance cases: numbers.\n")
    expect(frac).to include("# AsciiMath conformance cases: frac.\n")
    expect(numbers).not_to eq(frac)
  end
end
