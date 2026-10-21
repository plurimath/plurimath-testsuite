# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Meaningful portable fixture observations" do
  def case_schema(family)
    original = JSON.parse(File.read(File.join(REPO_ROOT, "schema", "#{family}-expectations.json")))
    item = family == "grammar" ? { "$ref" => "#/$defs/case" } : original.fetch("properties").fetch("cases").fetch("items")
    build_schema({ "$defs" => original.fetch("$defs") }, properties: { "case" => item })
  end

  def build_only
    { "steps" => [{ "kind" => "build", "save" => "v1", "recipe" => { "kind" => "literal", "value" => "x" } }],
      "assertion_lines" => [1] }
  end

  it "rejects renderer programs with no assertion or explicit acceptance" do
    row = { "id" => "review-empty-program", "description" => "no observation", "program" => build_only,
            "source" => { "path" => "spec/plurimath/asciimath_spec.rb", "line" => 1, "assertion_line" => 1 } }
    schema = case_schema("renderer")
    expect(errors_for(schema, { "case" => row })).not_to be_empty
    row.fetch("program")["no_error"] = true
    expect(errors_for(schema, { "case" => row })).to be_empty
    row.fetch("program").delete("no_error")
    row.fetch("program").fetch("steps") << { "kind" => "assert", "source" => "v1", "comparison" => "eq", "expected" => "x", "assertion_line" => 1 }
    expect(errors_for(schema, { "case" => row })).to be_empty
  end

  it "rejects facade programs with no check step" do
    row = { "id" => "facade-review-1", "label" => "no observation", "configuration" => {}, "program" => build_only,
            "source" => { "file" => "spec/plurimath/math_spec.rb", "line" => 1, "sha256" => "a" * 64 } }
    schema = case_schema("facade")
    expect(errors_for(schema, { "case" => row })).not_to be_empty
    row.fetch("program").fetch("steps") << { "kind" => "build", "save" => "v2", "recipe" => { "kind" => "literal", "value" => "x" } }
    row.fetch("program").fetch("steps") << { "kind" => "assert", "source" => "v1", "comparison" => "eq", "expected_slot" => "v2", "assertion_line" => 1 }
    expect(errors_for(schema, { "case" => row })).to be_empty
  end

  it "rejects grammar reads without a comparison and preserves string-key projections" do
    row = { "format" => "latex", "id" => "grammar-latex-001", "input" => "x", "label" => "read only", "locale" => nil,
            "rule" => "expression", "source" => { "path" => "spec/plurimath/latex/parse_spec.rb", "line" => 1 },
            "transforms" => [], "observations" => [{ "comparison" => "read", "path" => [] }] }
    schema = case_schema("grammar")
    expect(errors_for(schema, { "case" => row })).not_to be_empty
    row.fetch("observations") << { "comparison" => "eq", "path" => ["string-key"], "expected" => "x" }
    expect(errors_for(schema, { "case" => row })).to be_empty
  end
end
