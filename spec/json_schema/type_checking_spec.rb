# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Testsuite::JsonSchema::Schema, "type checking" do
  it "names the expected and actual types" do
    schema = build_schema(properties: { "x" => { "type" => "string" } })
    expect(errors_for(schema, { "x" => 7 }).first)
      .to include("expected string, got integer")
  end

  it "accepts a whole-valued float as an integer, per JSON Schema" do
    schema = build_schema(properties: { "x" => { "type" => "integer" } })
    expect(errors_for(schema, { "x" => 2.0 })).to be_empty
    expect(errors_for(schema, { "x" => 2.5 })).not_to be_empty
  end

  it "does not let booleans pass as numbers" do
    schema = build_schema(properties: { "x" => { "type" => "number" } })
    expect(errors_for(schema, { "x" => true })).not_to be_empty
  end

  it "supports a union of types" do
    schema = build_schema(properties: { "x" => { "type" => %w[string null] } })
    expect(errors_for(schema, { "x" => nil })).to be_empty
    expect(errors_for(schema, { "x" => "s" })).to be_empty
    expect(errors_for(schema,
                      { "x" => 1 }).first).to include("expected string or null")
  end
end
