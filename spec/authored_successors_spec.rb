# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../scripts/validate-facade-successors"

RSpec.describe "Authored writer successors" do
  let(:profile) { FacadeSuccessors.load(REPO_ROOT, "writer-authored-v1") }

  def original(entry)
    YAML.safe_load_file(File.join(REPO_ROOT, entry.fetch("source").fetch("path")), aliases: false)
      .fetch("cases").find { |row| row.fetch("id") == entry.fetch("source").fetch("id") }
  end

  it "validates six successors with five changed color assertions and one refusal row" do
    expect(profile.fetch("cases").size).to eq(6)
    expect(profile.fetch("cases").count { |row| row.key?("renderer_assertions") }).to eq(5)
    expect(profile.fetch("cases").count { |row| row.key?("refusals") }).to eq(1)
  end

  it "changes only the named color assertion, keeping other formats and frozen slots" do
    entry = profile.fetch("cases").find { |row| row.fetch("source").fetch("id").include?("math_zone-2578") }
    row = original(entry)
    before = Marshal.load(Marshal.dump(row))
    selected = FacadeSuccessors.apply(row, entry)
    steps = selected.fetch("program").fetch("steps")
    line = entry.fetch("renderer_assertions").first.fetch("assertion_line")
    changed = steps.find { |step| step["kind"] == "assert" && step["assertion_line"] == line }
    expect(changed.fetch("expected")).to include("FF0000")
    expect(changed).not_to have_key("expected_slot")
    keep = ->(items) { items.reject { |step| step["kind"] == "assert" && step["assertion_line"] == line } }
    expect(keep.call(steps)).to eq(keep.call(row.fetch("program").fetch("steps")))
    expect(row).to eq(before)
  end

  it "retains the simple OMML renderer operation and replaces only its expected output" do
    entry = profile.fetch("cases").find { |row| row.fetch("source").fetch("id").include?("line_breaks") }
    row = original(entry)
    selected = FacadeSuccessors.apply(row, entry)
    expect(selected.reject { |key, _| %w[id expected].include?(key) })
      .to eq(row.reject { |key, _| %w[id expected].include?(key) })
    expect(selected.fetch("expected")).to include("FF0000")
  end

  it "retains the enclosure MathML write and decode between both exact refusals" do
    entry = profile.fetch("cases").find { |row| row.key?("refusals") }
    row = original(entry)
    steps = FacadeSuccessors.apply(row, entry).fetch("program").fetch("steps")
    expect(steps.count { |step| step["kind"] == "assert_refusal" }).to eq(2)
    %w[v4 v5].each do |slot|
      expect(steps.find { |step| step["save"] == slot })
        .to eq(row.fetch("program").fetch("steps").find { |step| step["save"] == slot })
    end
  end

  it "rejects unknown and duplicate assertion lines" do
    entry = Marshal.load(Marshal.dump(profile.fetch("cases").find { |item| item.key?("renderer_assertions") }))
    row = original(entry)
    bad = Marshal.load(Marshal.dump(entry))
    bad.fetch("renderer_assertions").first["assertion_line"] = 999999
    expect { FacadeSuccessors.apply(row, bad) }.to raise_error(FacadeSuccessors::Error, /exactly one/)
    entry.fetch("renderer_assertions") << entry.fetch("renderer_assertions").first.dup
    expect { FacadeSuccessors.apply(row, entry) }.to raise_error(FacadeSuccessors::Error, /duplicate/)
  end

  it "rejects unchanged output and non-equality assertions" do
    entry = Marshal.load(Marshal.dump(profile.fetch("cases").find { |item| item.fetch("source").fetch("id").include?("line_breaks") }))
    row = original(entry)
    entry.fetch("renderer_assertions").first["expected"] = row.fetch("expected")
    expect { FacadeSuccessors.apply(row, entry) }.to raise_error(FacadeSuccessors::Error, /must change/)
    entry.fetch("renderer_assertions").first["expected"] = "new"
    row["comparison"] = "not_eq"
    expect { FacadeSuccessors.apply(row, entry) }.to raise_error(FacadeSuccessors::Error, /equality/)
  end

  it "rejects combined successor types in the schema" do
    data = Marshal.load(Marshal.dump(profile))
    data.fetch("cases").first["refusals"] = profile.fetch("cases").find { |item| item.key?("refusals") }.fetch("refusals")
    schema = JSON.parse(File.read(File.join(REPO_ROOT, "schema/facade-successors.json")))
    expect(Testsuite::JsonSchema::Schema.new(schema, "facade").validate(data)).not_to be_empty
  end
end
