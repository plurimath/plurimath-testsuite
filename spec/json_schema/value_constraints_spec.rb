# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Testsuite::JsonSchema::Schema, "value constraints" do
  it "checks enum membership" do
    schema = build_schema(properties: { "x" => { "enum" => %w[a b] } })
    expect(errors_for(schema, { "x" => "a" })).to be_empty
    expect(errors_for(schema, { "x" => "c" }).first)
      .to include('is not one of "a", "b"')
  end

  it "checks const equality" do
    schema = build_schema(properties: { "x" => { "const" => true } })
    expect(errors_for(schema, { "x" => false }).first)
      .to include("expected true, got false")
  end

  it "checks string length bounds" do
    schema = build_schema(properties: { "x" => { "minLength" => 2,
                                                 "maxLength" => 3 } })
    expect(errors_for(schema, { "x" => "ab" })).to be_empty
    expect(errors_for(schema, { "x" => "a" }).first)
      .to include("is shorter than 2 characters")
    expect(errors_for(schema, { "x" => "abcd" }).first)
      .to include("is longer than 3 characters")
  end

  it "checks the numeric bounds and multipleOf" do
    schema = build_schema(properties: { "x" => {
                            "minimum" => 0, "maximum" => 10, "multipleOf" => 2
                          } })
    expect(errors_for(schema, { "x" => 4 })).to be_empty
    expect(errors_for(schema, { "x" => -2 }).first).to include("is less than 0")
    expect(errors_for(schema, { "x" => 12 }).first)
      .to include("is greater than 10")
    expect(errors_for(schema, { "x" => 3 }).first)
      .to include("is not a multiple of 2")
  end

  it "checks the exclusive numeric bounds" do
    schema = build_schema(properties: { "x" => {
                            "exclusiveMinimum" => 0, "exclusiveMaximum" => 10
                          } })
    expect(errors_for(schema, { "x" => 5 })).to be_empty
    expect(errors_for(schema, { "x" => 0 }).first)
      .to include("is not greater than 0")
    expect(errors_for(schema, { "x" => 10 }).first)
      .to include("is not less than 10")
  end

  it "checks array length bounds" do
    schema = build_schema(properties: { "x" => { "minItems" => 1,
                                                 "maxItems" => 2 } })
    expect(errors_for(schema, { "x" => [] }).first)
      .to include("needs at least 1")
    expect(errors_for(schema, { "x" => [1, 2, 3] }).first)
      .to include("allows at most 2")
  end

  it "names the duplicates uniqueItems found" do
    schema = build_schema(properties: { "x" => { "uniqueItems" => true } })
    expect(errors_for(schema, { "x" => %w[a b a] }).first)
      .to include('has duplicate item(s): "a"')
  end

  it "applies prefixItems positionally and items to the rest" do
    schema = build_schema(properties: { "x" => {
                            "prefixItems" => [{ "type" => "string" }],
                            "items" => { "type" => "integer" },
                          } })
    expect(errors_for(schema, { "x" => ["s", 1, 2] })).to be_empty
    expect(errors_for(schema, { "x" => [1] }).first)
      .to include("/x/0: expected string")
    expect(errors_for(schema, { "x" => ["s", "t"] }).first)
      .to include("/x/1: expected integer")
  end

  it "checks object property-count bounds" do
    schema = build_schema(properties: { "x" => {
                            "minProperties" => 1, "maxProperties" => 2
                          } })
    expect(errors_for(schema, { "x" => {} }).first)
      .to include("needs at least 1")
    expect(errors_for(schema,
                      { "x" => { "a" => 1, "b" => 2, "c" => 3 } }).first)
      .to include("allows at most 2")
  end

  it "reports every missing required property" do
    schema = build_schema(properties: { "x" => { "required" => %w[a b] } })
    errors = errors_for(schema, { "x" => {} })
    expect(errors[0]).to include("is missing the required property `a`")
    expect(errors[1]).to include("is missing the required property `b`")
  end

  it "rejects properties outside additionalProperties: false" do
    schema = build_schema(properties: { "x" => {
                            "properties" => { "a" => true },
                            "additionalProperties" => false,
                          } })
    expect(errors_for(schema, { "x" => { "a" => 1 } })).to be_empty
    expect(errors_for(schema, { "x" => { "b" => 1 } }).first)
      .to include("/x/b: is not an allowed property")
  end

  it "validates extra properties against an additionalProperties schema" do
    schema = build_schema(properties: { "x" => {
                            "additionalProperties" => { "type" => "string" },
                          } })
    expect(errors_for(schema, { "x" => { "any" => "s" } })).to be_empty
    expect(errors_for(schema, { "x" => { "any" => 1 } })).not_to be_empty
  end

  it "counts patternProperties matches as matched, not additional" do
    schema = build_schema(properties: { "x" => {
                            "patternProperties" => {
                              "^n_" => { "type" => "integer" },
                            },
                            "additionalProperties" => false,
                          } })
    expect(errors_for(schema, { "x" => { "n_1" => 1 } })).to be_empty
    expect(errors_for(schema, { "x" => { "n_1" => "s" } })).not_to be_empty
    expect(errors_for(schema, { "x" => { "other" => 1 } })).not_to be_empty
  end

  it "wraps propertyNames violations into one readable error" do
    schema = build_schema(properties: { "x" => {
                            "propertyNames" => { "pattern" => "^[a-z]+$" },
                          } })
    expect(errors_for(schema, { "x" => { "BAD" => 1 } }).first)
      .to include("is not an allowed property name")
  end

  it "reports a non-string mapping key wherever it appears" do
    schema = build_schema(properties: { "x" => { "type" => "object" } })
    expect(errors_for(schema, { "x" => { 1 => "v" } }).first)
      .to include("has the non-string key 1")
  end

  it "escapes ~ and / in JSON-pointer property tokens" do
    schema = build_schema(
      properties: { "x" => { "additionalProperties" => false } },
    )
    expect(errors_for(schema, { "x" => { "we/ird~key" => 1 } }).first)
      .to include("/x/we~1ird~0key: is not an allowed property")
  end

  it "truncates oversized values in error messages" do
    truncated = Testsuite::JsonSchema.truncate("x" * 100)
    expect(truncated.length).to eq(60)
    expect(truncated).to end_with("...")
  end
end
