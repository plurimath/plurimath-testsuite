# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../scripts/validate-facade-successors"

RSpec.describe FacadeSuccessors do
  let(:profile) { described_class.load(REPO_ROOT, "writer-fidelity-v1") }

  it "validates eighteen proposed successors without modifying their frozen sources" do
    expect(profile.fetch("cases").size).to eq(18)
    expect(profile.fetch("cases").count { |row| row.key?("expected") }).to eq(17)
    expect(profile.fetch("cases").count { |row| row.key?("refusals") }).to eq(1)
  end

  it "preserves every unrelated field and target in a corpus row" do
    entry = profile.fetch("cases").find { |row| row.fetch("source").fetch("id") == "mathml-fences-021" }
    rows = YAML.safe_load_file(File.join(REPO_ROOT, entry.fetch("source").fetch("path")), aliases: false).fetch("cases")
    original = Marshal.load(Marshal.dump(rows))
    selected = described_class.select(profile, entry.fetch("source").fetch("path"), rows)
    old = rows.find { |row| row.fetch("id") == "mathml-fences-021" }
    successor = selected.find { |row| row.fetch("id") == entry.fetch("id") }
    expect(successor.reject { |key, _| %w[id expected].include?(key) }).to eq(old.reject { |key, _| %w[id expected].include?(key) })
    expect(successor.fetch("expected").reject { |key, _| key == "latex" }).to eq(old.fetch("expected").reject { |key, _| key == "latex" })
    expect(successor.fetch("expected").fetch("latex")).to include("\\operatorname{lcm}")
    expect(selected.size).to eq(rows.size)
    expect(rows).to eq(original)
    expect(described_class.select(profile, "corpus/mathml/unselected.yaml", rows)).to eq(rows)
  end

  it "retains the renderer's MathML assertion while making both refusals explicit" do
    entry = profile.fetch("cases").find { |row| row.key?("refusals") }
    row = YAML.safe_load_file(File.join(REPO_ROOT, entry.fetch("source").fetch("path")), aliases: false).fetch("cases").find { |item| item.fetch("id") == entry.fetch("source").fetch("id") }
    original = Marshal.load(Marshal.dump(row))
    selected = described_class.apply(row, entry)
    steps = selected.fetch("program").fetch("steps")
    expect(steps.count { |step| step["kind"] == "assert_refusal" }).to eq(2)
    expect(steps.find { |step| step["save"] == "v7" }).to eq(row.fetch("program").fetch("steps").find { |step| step["save"] == "v7" })
    expect(steps.find { |step| step["assertion_line"] == 854 }).to eq(row.fetch("program").fetch("steps").find { |step| step["assertion_line"] == 854 })
    expect(row).to eq(original)
  end

  it "rejects a missing or duplicate selected source rather than silently skipping it" do
    entry = profile.fetch("cases").first
    expect { described_class.select(profile, entry.fetch("source").fetch("path"), []) }.to raise_error(described_class::Error, /missing or duplicated/)
    row = { "id" => entry.fetch("source").fetch("id") }
    expect { described_class.select(profile, entry.fetch("source").fetch("path"), [row, row]) }.to raise_error(described_class::Error, /missing or duplicated/)
  end

  it "rejects checksum changes before selecting any rows" do
    Dir.mktmpdir do |root|
      %w[schema contracts].each { |dir| FileUtils.cp_r(File.join(REPO_ROOT, dir), root) }
      profile.fetch("cases").map { |row| row.fetch("source").fetch("path") }.uniq.each do |path|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        FileUtils.cp(File.join(REPO_ROOT, path), File.join(root, path))
      end
      path = profile.fetch("cases").first.fetch("source").fetch("path")
      File.open(File.join(root, path), "a") { |file| file.puts "# changed" }
      expect { described_class.load(root, "writer-fidelity-v1") }.to raise_error(described_class::Error, /source checksum differs/)
    end
  end

  it "rejects edits to existing profiles and frozen payloads against the base" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "contracts/facade"))
      path = File.join(root, "contracts/facade/existing-v1.json")
      File.write(path, "original\n")
      run = lambda do |*args|
        _, error, status = Open3.capture3("git", "-C", root, *args)
        raise error unless status.success?
      end
      run.call("init", "--quiet")
      run.call("add", "contracts/facade/existing-v1.json")
      run.call("-c", "user.name=spec", "-c", "user.email=spec@example.test", "commit", "--quiet", "-m", "Initial profile")
      expect { described_class.validate_base!(root, "HEAD") }.not_to raise_error
      File.write(File.join(root, "contracts/facade/added-v2.json"), "new\n")
      expect { described_class.validate_base!(root, "HEAD") }.not_to raise_error
      File.write(path, "changed\n")
      expect { described_class.validate_base!(root, "HEAD") }.to raise_error(described_class::Error, /frozen payloads or profiles changed/)
    end
  end

  it "lets the ledger be appended against the base; validate-stages owns the prefix rule" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "generations"))
      path = File.join(root, "generations/mathml.yaml")
      File.write(path, "entries: []\n")
      run = lambda do |*args|
        _, error, status = Open3.capture3("git", "-C", root, *args)
        raise error unless status.success?
      end
      run.call("init", "--quiet")
      run.call("add", "generations/mathml.yaml")
      run.call("-c", "user.name=spec", "-c", "user.email=spec@example.test", "commit", "--quiet", "-m", "Ledger at the base")
      expect { described_class.validate_base!(root, "HEAD") }.not_to raise_error
      File.open(path, "a") { |file| file.puts("- generation: 4\n") }
      expect { described_class.validate_base!(root, "HEAD") }.not_to raise_error
      File.write(File.join(root, "generations/other.yaml"), "entries: []\n")
      expect { described_class.validate_base!(root, "HEAD") }.not_to raise_error
    end
  end
end
