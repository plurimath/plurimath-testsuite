# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Testsuite::JsonSchema::Schema, "array contains" do
  it "requires a matching item independently of ordinary items" do
    schema = build_schema(properties: { "x" => { "type" => "array", "items" => { "type" => "integer" }, "contains" => { "const" => 2 } } })
    expect(errors_for(schema, { "x" => [1, 2] })).to be_empty
    expect(errors_for(schema, { "x" => [1, 3] }).join).to include("contains schema")
    expect(errors_for(schema, { "x" => [2, "bad"] }).join).to include("expected integer")
  end

  it "applies when items is absent and includes prefix items" do
    schema = build_schema(properties: { "x" => { "prefixItems" => [true], "contains" => { "const" => "first" } } })
    expect(errors_for(schema, { "x" => ["first", 2] })).to be_empty
    expect(errors_for(schema, { "x" => ["other", 2] })).not_to be_empty
  end

  it "handles boolean schemas and empty arrays" do
    denied = build_schema(properties: { "x" => { "contains" => false } })
    allowed = build_schema(properties: { "x" => { "contains" => true } })
    expect(errors_for(denied, { "x" => [1] })).not_to be_empty
    expect(errors_for(allowed, { "x" => [1] })).to be_empty
    expect(errors_for(allowed, { "x" => [] })).not_to be_empty
  end

  it "ignores contains for a non-array instance" do
    schema = build_schema(properties: { "x" => { "contains" => false } })
    expect(errors_for(schema, { "x" => "text" })).to be_empty
  end
end
