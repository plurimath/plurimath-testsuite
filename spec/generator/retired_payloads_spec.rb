# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../support/generator"

# Helpers for the retired-payload specs, kept out of the describe block.
module RetiredPayloadsSpecHelpers
  PREVIOUS_FILES = {
    "latex/kept.yaml" => "kept",
    "latex/left-right.yaml" => "retired",
    "latex/hand-made.yaml" => "never recorded",
    "notes.txt" => "unrelated",
  }.freeze

  # Writes PREVIOUS_FILES under `out` and records the `recorded` subset in a
  # provenance document, as an earlier generator run would have left it.
  def previous_run(out, recorded)
    PREVIOUS_FILES.each do |relative, content|
      path = File.join(out, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    payloads = recorded.map do |relative|
      [File.join(out, relative), PREVIOUS_FILES.fetch(relative)]
    end
    CorpusGenerator.write_provenance(out, provenance_stub, payloads)
  end

  def provenance_stub
    { "schema" => CorpusGenerator::PROVENANCE_SCHEMA }
  end

  # A provenance document whose `payloads` list is exactly `entries`.
  def write_entries(out, entries, schema: CorpusGenerator::PROVENANCE_SCHEMA)
    File.write(File.join(out, "provenance.yaml"),
               YAML.dump("schema" => schema, "payloads" => entries))
  end

  def entry(path)
    { "path" => path, "sha256" => "0" * 64, "bytes" => 1 }
  end

  def files_under(out)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: out)
      .select { |path| File.file?(File.join(out, path)) }.sort
  end
end

RSpec.describe CorpusGenerator, "retired payloads" do
  include RetiredPayloadsSpecHelpers

  it "removes a recorded payload this run no longer writes, and nothing else" do
    Dir.mktmpdir do |out|
      previous_run(out, ["latex/kept.yaml", "latex/left-right.yaml"])

      recorded = described_class.recorded_payload_paths(out)
      written = [[File.join(out, "latex", "kept.yaml"), "kept"]]
      described_class.discard_retired_payloads(out, recorded, written)

      expect(files_under(out)).to eq(%w[latex/hand-made.yaml latex/kept.yaml
                                        notes.txt provenance.yaml])
      expect(File.read(File.join(out, "latex", "hand-made.yaml")))
        .to eq("never recorded")
    end
  end

  it "records nothing without a provenance document it can read and parse" do
    Dir.mktmpdir do |out|
      expect(described_class.recorded_payload_paths(out)).to eq([])
      File.write(File.join(out, "provenance.yaml"), "payloads: [unclosed")
      expect(described_class.recorded_payload_paths(out)).to eq([])
      write_entries(out, [entry("latex/ok.yaml")])
      File.chmod(0o000, File.join(out, "provenance.yaml"))
      if File.readable?(File.join(out, "provenance.yaml"))
        skip "running as root, which can read any file"
      end

      expect(described_class.recorded_payload_paths(out)).to eq([])
    end
  end

  it "records nothing from a document that is not a provenance document" do
    Dir.mktmpdir do |out|
      write_entries(out, [entry("latex/ok.yaml")], schema: "unrelated")
      expect(described_class.recorded_payload_paths(out)).to eq([])
    end
  end

  it "records nothing from a provenance version it does not know" do
    Dir.mktmpdir do |out|
      %w[plurimath-corpus/provenance/not-a-version
         plurimath-corpus/provenance/4
         plurimath-corpus/provenance/1].each do |schema|
        write_entries(out, [entry("latex/ok.yaml")], schema: schema)
        expect(described_class.recorded_payload_paths(out)).to eq([])
      end
    end
  end

  it "records the payloads of a provenance/2 document" do
    Dir.mktmpdir do |out|
      write_entries(out, [entry("latex/ok.yaml")],
                    schema: "plurimath-corpus/provenance/2")
      expect(described_class.recorded_payload_paths(out))
        .to eq([File.join(File.expand_path(out), "latex/ok.yaml")])
    end
  end

  it "ignores recorded paths that leave the output root or are not payloads" do
    Dir.mktmpdir do |out|
      paths = ["../outside.yaml", "/abs/x.yaml", "latex/../../x.yaml",
               "notes.txt", "provenance.yaml", 7, "latex/nul\0.yaml",
               "latex/ok.yaml"]
      incomplete = { "path" => "latex/incomplete.yaml" }
      write_entries(out, paths.map { |path| entry(path) } +
                         [incomplete, "latex/bare.yaml"])

      expect(described_class.recorded_payload_paths(out))
        .to eq([File.join(File.expand_path(out), "latex", "ok.yaml")])
    end
  end

  it "does not follow a symlinked directory out of the output root" do
    Dir.mktmpdir do |outside|
      Dir.mktmpdir do |out|
        File.write(File.join(outside, "victim.yaml"), "keep me")
        File.symlink(outside, File.join(out, "linked"))
        write_entries(out, [entry("linked/victim.yaml")])

        recorded = described_class.recorded_payload_paths(out)
        described_class.discard_retired_payloads(out, recorded, [])

        expect(File.read(File.join(outside, "victim.yaml"))).to eq("keep me")
      end
    end
  end

  it "does not follow a symlinked directory inside the output root" do
    Dir.mktmpdir do |out|
      FileUtils.mkdir_p(File.join(out, "notes"))
      File.write(File.join(out, "notes", "left-right.yaml"), "unrecorded")
      File.symlink(File.join(out, "notes"), File.join(out, "latex"))
      write_entries(out, [entry("latex/left-right.yaml")])

      recorded = described_class.recorded_payload_paths(out)
      described_class.discard_retired_payloads(out, recorded, [])

      expect(File.read(File.join(out, "notes", "left-right.yaml")))
        .to eq("unrecorded")
    end
  end
end
