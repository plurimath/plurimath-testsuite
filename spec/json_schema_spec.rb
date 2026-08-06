# frozen_string_literal: true

# Unit specs for the JSON Schema subset scripts/validate.rb implements.
# Exercised directly through Testsuite::JsonSchema::Schema, so a dropped or
# quietly-weakened keyword fails here even before any corpus fixture does.

require_relative "spec_helper"

RSpec.describe "JsonSchema schema linting" do
  it "rejects a schema that is not an object" do
    expect { Testsuite::JsonSchema::Schema.new(["not", "a", "schema"], "lint") }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("must be a JSON object")
      }
  end

  it "rejects a schema without the 2020-12 dialect" do
    expect { build_schema({ "$schema" => "http://json-schema.org/draft-07/schema#" }) }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("$schema must be")
      }
  end

  it "rejects an $id without a version segment" do
    expect { build_schema({ "$id" => "https://example.test/schema/unit" }) }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("$id must end in a version segment")
      }
  end

  it "rejects a schema that does not pin the payload kind" do
    document = {
      "$schema" => Testsuite::JsonSchema::DIALECT,
      "$id" => "https://example.test/schema/unit/1",
      "properties" => { "schema" => { "type" => "string" } },
    }
    expect { Testsuite::JsonSchema::Schema.new(document, "lint") }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("must pin the payload kind")
      }
  end

  it "rejects any keyword outside the implemented whitelist" do
    expect { build_schema({ "contains" => { "type" => "string" } }) }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("uses `contains`, which this validator does not implement")
      }
  end

  it "rejects unimplemented keywords in nested subschemas too" do
    expect { build_schema(properties: { "x" => { "unevaluatedProperties" => false } }) }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("#/properties/x uses `unevaluatedProperties`")
      }
  end

  it "rejects a pattern that does not compile, at load time" do
    expect { build_schema(properties: { "x" => { "pattern" => "([" } }) }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("does not compile")
      }
  end

  it "rejects external $ref targets" do
    expect { build_schema(properties: { "x" => { "$ref" => "https://example.test/other#/x" } }) }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("only local #/... references are supported")
      }
  end

  it "rejects a $ref that resolves to nothing" do
    expect { build_schema(properties: { "x" => { "$ref" => "#/$defs/missing" } }) }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("references #/$defs/missing, which does not exist")
      }
  end

  it "unescapes ~1 and ~0 in $ref pointer tokens" do
    schema = build_schema(
      { "$defs" => { "a/b" => { "type" => "integer" } } },
      properties: { "x" => { "$ref" => "#/$defs/a~1b" } },
    )
    expect(errors_for(schema, { "x" => 3 })).to be_empty
    expect(errors_for(schema, { "x" => "s" }).first).to include("expected integer")
  end

  it "rejects a map-valued keyword that is not an object" do
    expect { build_schema({ "$defs" => ["not", "a", "map"] }) }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("#/$defs must be an object")
      }
  end

  it "rejects a list-valued keyword that is not an array" do
    expect { build_schema({ "allOf" => { "type" => "object" } }) }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("#/allOf must be an array")
      }
  end

  it "raises on an unknown type name rather than guessing" do
    schema = build_schema(properties: { "x" => { "type" => "float" } })
    expect { schema.validate({ "x" => 1.5 }) }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include('unknown type "float"')
      }
  end

  it "exposes what declaration the schema claims, const or pattern" do
    expect(build_schema.declares).to eq("unit/1")
    expect(build_schema.accepts_declaration?("unit/1")).to be_truthy
    expect(build_schema.accepts_declaration?("other/1")).to be_falsey
    expect(build_schema.accepts_declaration?(5)).to be_falsey

    patterned = build_schema(properties: { "schema" => { "pattern" => "^unit/(a|b)/1$" } })
    expect(patterned.accepts_declaration?("unit/a/1")).to be_truthy
    expect(patterned.accepts_declaration?("unit/c/1")).to be_falsey
  end
end

RSpec.describe "JsonSchema pattern translation (ECMA anchors)" do
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

RSpec.describe "JsonSchema type checking" do
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
    expect(errors_for(schema, { "x" => 1 }).first).to include("expected string or null")
  end
end

RSpec.describe "JsonSchema value constraints" do
  it "checks enum membership" do
    schema = build_schema(properties: { "x" => { "enum" => %w[a b] } })
    expect(errors_for(schema, { "x" => "a" })).to be_empty
    expect(errors_for(schema, { "x" => "c" }).first).to include('is not one of "a", "b"')
  end

  it "checks const equality" do
    schema = build_schema(properties: { "x" => { "const" => true } })
    expect(errors_for(schema, { "x" => false }).first).to include("expected true, got false")
  end

  it "checks string length bounds" do
    schema = build_schema(properties: { "x" => { "minLength" => 2, "maxLength" => 3 } })
    expect(errors_for(schema, { "x" => "ab" })).to be_empty
    expect(errors_for(schema, { "x" => "a" }).first).to include("is shorter than 2 characters")
    expect(errors_for(schema, { "x" => "abcd" }).first).to include("is longer than 3 characters")
  end

  it "checks the numeric bounds and multipleOf" do
    schema = build_schema(properties: { "x" => {
      "minimum" => 0, "maximum" => 10, "multipleOf" => 2
    } })
    expect(errors_for(schema, { "x" => 4 })).to be_empty
    expect(errors_for(schema, { "x" => -2 }).first).to include("is less than 0")
    expect(errors_for(schema, { "x" => 12 }).first).to include("is greater than 10")
    expect(errors_for(schema, { "x" => 3 }).first).to include("is not a multiple of 2")
  end

  it "checks the exclusive numeric bounds" do
    schema = build_schema(properties: { "x" => {
      "exclusiveMinimum" => 0, "exclusiveMaximum" => 10
    } })
    expect(errors_for(schema, { "x" => 5 })).to be_empty
    expect(errors_for(schema, { "x" => 0 }).first).to include("is not greater than 0")
    expect(errors_for(schema, { "x" => 10 }).first).to include("is not less than 10")
  end

  it "checks array length bounds" do
    schema = build_schema(properties: { "x" => { "minItems" => 1, "maxItems" => 2 } })
    expect(errors_for(schema, { "x" => [] }).first).to include("needs at least 1")
    expect(errors_for(schema, { "x" => [1, 2, 3] }).first).to include("allows at most 2")
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
    expect(errors_for(schema, { "x" => [1] }).first).to include("/x/0: expected string")
    expect(errors_for(schema, { "x" => ["s", "t"] }).first).to include("/x/1: expected integer")
  end

  it "checks object property-count bounds" do
    schema = build_schema(properties: { "x" => {
      "minProperties" => 1, "maxProperties" => 2
    } })
    expect(errors_for(schema, { "x" => {} }).first).to include("needs at least 1")
    expect(errors_for(schema, { "x" => { "a" => 1, "b" => 2, "c" => 3 } }).first)
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
      "properties" => { "a" => true }, "additionalProperties" => false
    } })
    expect(errors_for(schema, { "x" => { "a" => 1 } })).to be_empty
    expect(errors_for(schema, { "x" => { "b" => 1 } }).first)
      .to include("/x/b: is not an allowed property")
  end

  it "validates extra properties against an additionalProperties schema" do
    schema = build_schema(properties: { "x" => {
      "additionalProperties" => { "type" => "string" }
    } })
    expect(errors_for(schema, { "x" => { "any" => "s" } })).to be_empty
    expect(errors_for(schema, { "x" => { "any" => 1 } })).not_to be_empty
  end

  it "counts patternProperties matches as matched, not additional" do
    schema = build_schema(properties: { "x" => {
      "patternProperties" => { "^n_" => { "type" => "integer" } },
      "additionalProperties" => false,
    } })
    expect(errors_for(schema, { "x" => { "n_1" => 1 } })).to be_empty
    expect(errors_for(schema, { "x" => { "n_1" => "s" } })).not_to be_empty
    expect(errors_for(schema, { "x" => { "other" => 1 } })).not_to be_empty
  end

  it "wraps propertyNames violations into one readable error" do
    schema = build_schema(properties: { "x" => {
      "propertyNames" => { "pattern" => "^[a-z]+$" }
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
    schema = build_schema(properties: { "x" => { "additionalProperties" => false } })
    expect(errors_for(schema, { "x" => { "we/ird~key" => 1 } }).first)
      .to include("/x/we~1ird~0key: is not an allowed property")
  end

  it "truncates oversized values in error messages" do
    truncated = Testsuite::JsonSchema.truncate("x" * 100)
    expect(truncated.length).to eq(60)
    expect(truncated).to end_with("...")
  end
end

RSpec.describe "JsonSchema combinators" do
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
      "not" => { "required" => ["legacy"] }
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
    expect(errors_for(schema, { "x" => { "class" => "C", "fields" => {} } })).to be_empty
    expect(errors_for(schema, { "x" => { "class" => "C" } }).first)
      .to include("is missing the required property `fields`")
    expect(errors_for(schema, { "x" => {} }).first)
      .to include("is missing the required property `value`")
  end

  it "a `false` subschema allows nothing, `true` allows anything" do
    schema = build_schema(properties: { "x" => false, "y" => true })
    expect(errors_for(schema, { "x" => 1 }).first).to include("no value is allowed here")
    expect(errors_for(schema, { "y" => ["anything", { "at" => "all" }] })).to be_empty
  end
end
