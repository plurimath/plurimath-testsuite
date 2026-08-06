# frozen_string_literal: true

# JSON Schema patterns are ECMA-262: `^` and `$` anchor the whole string,
# while Ruby's anchor to a line. The translation is what keeps a newline from
# slipping a value past an anchored pattern.

require_relative "../spec_helper"

RSpec.describe Testsuite::JsonSchema::Schema,
               "pattern translation (ECMA anchors)" do
  it "anchors ^ and $ to the whole string, not to lines" do
    schema = build_schema(properties: { "x" => { "pattern" => "^[a-z]+$" } })
    expect(errors_for(schema, { "x" => "abc" })).to be_empty
    expect(errors_for(schema, { "x" => "abc\nxyz" }))
      .not_to be_empty, "a newline slipped through an anchored pattern"
  end

  it "rejects a trailing newline (\\z, not \\Z)" do
    schema = build_schema(properties: { "x" => { "pattern" => "^[a-z]+$" } })
    expect(errors_for(schema, { "x" => "abc\n" })).not_to be_empty
  end

  it "leaves ^ inside a character class as negation" do
    schema = build_schema(properties: { "x" => { "pattern" => "^[^a]+$" } })
    expect(errors_for(schema, { "x" => "bcd" })).to be_empty
    expect(errors_for(schema, { "x" => "a" })).not_to be_empty
  end

  it "leaves an escaped \\$ literal" do
    schema = build_schema(properties: { "x" => { "pattern" => "^a\\$b$" } })
    expect(errors_for(schema, { "x" => "a$b" })).to be_empty
    expect(errors_for(schema, { "x" => "ab" })).not_to be_empty
  end
end
