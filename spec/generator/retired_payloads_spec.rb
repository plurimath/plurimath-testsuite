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
    CorpusGenerator.write_provenance(out, { "schema" => "s" }, payloads)
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
      described_class.discard_retired_payloads(recorded, written)

      expect(files_under(out)).to eq(%w[latex/hand-made.yaml latex/kept.yaml
                                        notes.txt provenance.yaml])
      expect(File.read(File.join(out, "latex", "hand-made.yaml")))
        .to eq("never recorded")
    end
  end

  it "records nothing, and so removes nothing, without a readable provenance" do
    Dir.mktmpdir do |out|
      expect(described_class.recorded_payload_paths(out)).to eq([])
      File.write(File.join(out, "provenance.yaml"), "payloads: [unclosed")
      expect(described_class.recorded_payload_paths(out)).to eq([])
    end
  end

  it "ignores recorded paths that leave the output root or are not payloads" do
    Dir.mktmpdir do |out|
      paths = ["../outside.yaml", "/abs/x.yaml", "latex/../../x.yaml",
               "notes.txt", "provenance.yaml", 7, "latex/ok.yaml"]
      entries = paths.map { |path| { "path" => path } } + ["latex/bare.yaml"]
      File.write(File.join(out, "provenance.yaml"),
                 YAML.dump("payloads" => entries))

      expect(described_class.recorded_payload_paths(out))
        .to eq([File.join(File.expand_path(out), "latex", "ok.yaml")])
    end
  end
end
