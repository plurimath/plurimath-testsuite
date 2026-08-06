# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Testsuite::JsonSchema::Schema, "combinators" do
  it "allOf applies every branch" do
    schema = build_schema(properties: { "x" => { "allOf" => [
                            { "type" => "string" }, { "minLength" => 2 }
                          ] } })
    expect(errors_for(schema, { "x" => "ab" })).to be_empty
    expect(errors_for(schema, { "x" => "a" })).not_to be_empty
  end

  it "anyOf reports the closest branch when nothing matches" do
    schema = build_schema(properties: { "x" => { "anyOf" => [
                            { "type" => "string" },
                            { "type" => "object", "required" => ["a"] },
                          ] } })
    expect(errors_for(schema, { "x" => "s" })).to be_empty
    expect(errors_for(schema, { "x" => { "a" => 1 } })).to be_empty
    errors = errors_for(schema, { "x" => 5 })
    expect(errors.first).to include("matches none of the 2 anyOf alternatives")
    expect(errors.join("\n")).to include("the closest one reports:")
  end

  it "oneOf requires exactly one branch" do
    overlapping = build_schema(properties: { "x" => { "oneOf" => [
                                 { "type" => "string" }, { "minLength" => 1 }
                               ] } })
    expect(errors_for(overlapping, { "x" => "s" }).first)
      .to include("matches 2 of the oneOf alternatives, expected exactly 1")
    disjoint = build_schema(properties: { "x" => { "oneOf" => [
                              { "type" => "string" }, { "type" => "object" }
                            ] } })
    expect(errors_for(disjoint, { "x" => 5 }).first)
      .to include("matches none of the 2 oneOf alternatives")
    expect(errors_for(disjoint, { "x" => "s" })).to be_empty
  end

  it "not rejects a matching form and names its required keys" do
    schema = build_schema(properties: { "x" => {
                            "not" => { "required" => ["legacy"] },
                          } })
    expect(errors_for(schema, { "x" => {} })).to be_empty
    expect(errors_for(schema, { "x" => { "legacy" => 1 } }).first)
      .to include("matches a form that is not allowed here (has `legacy`)")
  end

  it "if/then/else takes the matching branch" do
    schema = build_schema(properties: { "x" => {
                            "if" => { "required" => ["class"] },
                            "then" => { "required" => ["fields"] },
                            "else" => { "required" => ["value"] },
                          } })
    valid = { "x" => { "class" => "C", "fields" => {} } }
    expect(errors_for(schema, valid)).to be_empty
    expect(errors_for(schema, { "x" => { "class" => "C" } }).first)
      .to include("is missing the required property `fields`")
    expect(errors_for(schema, { "x" => {} }).first)
      .to include("is missing the required property `value`")
  end

  it "a `false` subschema allows nothing, `true` allows anything" do
    schema = build_schema(properties: { "x" => false, "y" => true })
    expect(errors_for(schema, { "x" => 1 }).first)
      .to include("no value is allowed here")
    expect(errors_for(schema, { "y" => ["anything", { "at" => "all" }] }))
      .to be_empty
  end
end
