# frozen_string_literal: true

# Unit specs for the JSON Schema subset scripts/validate.rb implements.
# Exercised directly through Testsuite::JsonSchema::Schema, so a dropped or
# quietly-weakened keyword fails here even before any corpus fixture does.

require_relative "spec_helper"

describe "JsonSchema schema linting" do
  it "rejects a schema that is not an object" do
    error = assert_raises(Testsuite::Failure) do
      Testsuite::JsonSchema::Schema.new(["not", "a", "schema"], "lint")
    end
    assert_includes error.message, "must be a JSON object"
  end

  it "rejects a schema without the 2020-12 dialect" do
    error = assert_raises(Testsuite::Failure) do
      build_schema({ "$schema" => "http://json-schema.org/draft-07/schema#" })
    end
    assert_includes error.message, "$schema must be"
  end

  it "rejects an $id without a version segment" do
    error = assert_raises(Testsuite::Failure) do
      build_schema({ "$id" => "https://example.test/schema/unit" })
    end
    assert_includes error.message, "$id must end in a version segment"
  end

  it "rejects a schema that does not pin the payload kind" do
    document = {
      "$schema" => Testsuite::JsonSchema::DIALECT,
      "$id" => "https://example.test/schema/unit/1",
      "properties" => { "schema" => { "type" => "string" } },
    }
    error = assert_raises(Testsuite::Failure) do
      Testsuite::JsonSchema::Schema.new(document, "lint")
    end
    assert_includes error.message, "must pin the payload kind"
  end

  it "rejects any keyword outside the implemented whitelist" do
    error = assert_raises(Testsuite::Failure) do
      build_schema({ "contains" => { "type" => "string" } })
    end
    assert_includes error.message, "uses `contains`, which this validator does not implement"
  end

  it "rejects unimplemented keywords in nested subschemas too" do
    error = assert_raises(Testsuite::Failure) do
      build_schema(properties: { "x" => { "unevaluatedProperties" => false } })
    end
    assert_includes error.message, "#/properties/x uses `unevaluatedProperties`"
  end

  it "rejects a pattern that does not compile, at load time" do
    error = assert_raises(Testsuite::Failure) do
      build_schema(properties: { "x" => { "pattern" => "([" } })
    end
    assert_includes error.message, "does not compile"
  end

  it "rejects external $ref targets" do
    error = assert_raises(Testsuite::Failure) do
      build_schema(properties: { "x" => { "$ref" => "https://example.test/other#/x" } })
    end
    assert_includes error.message, "only local #/... references are supported"
  end

  it "rejects a $ref that resolves to nothing" do
    error = assert_raises(Testsuite::Failure) do
      build_schema(properties: { "x" => { "$ref" => "#/$defs/missing" } })
    end
    assert_includes error.message, "references #/$defs/missing, which does not exist"
  end

  it "unescapes ~1 and ~0 in $ref pointer tokens" do
    schema = build_schema(
      { "$defs" => { "a/b" => { "type" => "integer" } } },
      properties: { "x" => { "$ref" => "#/$defs/a~1b" } },
    )
    assert_empty errors_for(schema, { "x" => 3 })
    assert_includes errors_for(schema, { "x" => "s" }).first, "expected integer"
  end

  it "rejects a map-valued keyword that is not an object" do
    error = assert_raises(Testsuite::Failure) do
      build_schema({ "$defs" => ["not", "a", "map"] })
    end
    assert_includes error.message, "#/$defs must be an object"
  end

  it "rejects a list-valued keyword that is not an array" do
    error = assert_raises(Testsuite::Failure) do
      build_schema({ "allOf" => { "type" => "object" } })
    end
    assert_includes error.message, "#/allOf must be an array"
  end

  it "raises on an unknown type name rather than guessing" do
    schema = build_schema(properties: { "x" => { "type" => "float" } })
    error = assert_raises(Testsuite::Failure) { schema.validate({ "x" => 1.5 }) }
    assert_includes error.message, 'unknown type "float"'
  end

  it "exposes what declaration the schema claims, const or pattern" do
    assert_equal "unit/1", build_schema.declares
    assert build_schema.accepts_declaration?("unit/1")
    refute build_schema.accepts_declaration?("other/1")
    refute build_schema.accepts_declaration?(5)

    patterned = build_schema(properties: { "schema" => { "pattern" => "^unit/(a|b)/1$" } })
    assert patterned.accepts_declaration?("unit/a/1")
    refute patterned.accepts_declaration?("unit/c/1")
  end
end

describe "JsonSchema pattern translation (ECMA anchors)" do
  it "anchors ^ and $ to the whole string, not to lines" do
    schema = build_schema(properties: { "x" => { "pattern" => "^[a-z]+$" } })
    assert_empty errors_for(schema, { "x" => "abc" })
    refute_empty errors_for(schema, { "x" => "abc\nxyz" }),
                 "a newline slipped through an anchored pattern"
  end

  it "rejects a trailing newline (\\z, not \\Z)" do
    schema = build_schema(properties: { "x" => { "pattern" => "^[a-z]+$" } })
    refute_empty errors_for(schema, { "x" => "abc\n" })
  end

  it "leaves ^ inside a character class as negation" do
    schema = build_schema(properties: { "x" => { "pattern" => "^[^a]+$" } })
    assert_empty errors_for(schema, { "x" => "bcd" })
    refute_empty errors_for(schema, { "x" => "a" })
  end

  it "leaves an escaped \\$ literal" do
    schema = build_schema(properties: { "x" => { "pattern" => "^a\\$b$" } })
    assert_empty errors_for(schema, { "x" => "a$b" })
    refute_empty errors_for(schema, { "x" => "ab" })
  end
end

describe "JsonSchema type checking" do
  it "names the expected and actual types" do
    schema = build_schema(properties: { "x" => { "type" => "string" } })
    assert_includes errors_for(schema, { "x" => 7 }).first,
                    "expected string, got integer"
  end

  it "accepts a whole-valued float as an integer, per JSON Schema" do
    schema = build_schema(properties: { "x" => { "type" => "integer" } })
    assert_empty errors_for(schema, { "x" => 2.0 })
    refute_empty errors_for(schema, { "x" => 2.5 })
  end

  it "does not let booleans pass as numbers" do
    schema = build_schema(properties: { "x" => { "type" => "number" } })
    refute_empty errors_for(schema, { "x" => true })
  end

  it "supports a union of types" do
    schema = build_schema(properties: { "x" => { "type" => %w[string null] } })
    assert_empty errors_for(schema, { "x" => nil })
    assert_empty errors_for(schema, { "x" => "s" })
    assert_includes errors_for(schema, { "x" => 1 }).first, "expected string or null"
  end
end

describe "JsonSchema value constraints" do
  it "checks enum membership" do
    schema = build_schema(properties: { "x" => { "enum" => %w[a b] } })
    assert_empty errors_for(schema, { "x" => "a" })
    assert_includes errors_for(schema, { "x" => "c" }).first, 'is not one of "a", "b"'
  end

  it "checks const equality" do
    schema = build_schema(properties: { "x" => { "const" => true } })
    assert_includes errors_for(schema, { "x" => false }).first, "expected true, got false"
  end

  it "checks string length bounds" do
    schema = build_schema(properties: { "x" => { "minLength" => 2, "maxLength" => 3 } })
    assert_empty errors_for(schema, { "x" => "ab" })
    assert_includes errors_for(schema, { "x" => "a" }).first, "is shorter than 2 characters"
    assert_includes errors_for(schema, { "x" => "abcd" }).first, "is longer than 3 characters"
  end

  it "checks the numeric bounds and multipleOf" do
    schema = build_schema(properties: { "x" => {
      "minimum" => 0, "maximum" => 10, "multipleOf" => 2
    } })
    assert_empty errors_for(schema, { "x" => 4 })
    assert_includes errors_for(schema, { "x" => -2 }).first, "is less than 0"
    assert_includes errors_for(schema, { "x" => 12 }).first, "is greater than 10"
    assert_includes errors_for(schema, { "x" => 3 }).first, "is not a multiple of 2"
  end

  it "checks the exclusive numeric bounds" do
    schema = build_schema(properties: { "x" => {
      "exclusiveMinimum" => 0, "exclusiveMaximum" => 10
    } })
    assert_empty errors_for(schema, { "x" => 5 })
    assert_includes errors_for(schema, { "x" => 0 }).first, "is not greater than 0"
    assert_includes errors_for(schema, { "x" => 10 }).first, "is not less than 10"
  end

  it "checks array length bounds" do
    schema = build_schema(properties: { "x" => { "minItems" => 1, "maxItems" => 2 } })
    assert_includes errors_for(schema, { "x" => [] }).first, "needs at least 1"
    assert_includes errors_for(schema, { "x" => [1, 2, 3] }).first, "allows at most 2"
  end

  it "names the duplicates uniqueItems found" do
    schema = build_schema(properties: { "x" => { "uniqueItems" => true } })
    assert_includes errors_for(schema, { "x" => %w[a b a] }).first,
                    'has duplicate item(s): "a"'
  end

  it "applies prefixItems positionally and items to the rest" do
    schema = build_schema(properties: { "x" => {
      "prefixItems" => [{ "type" => "string" }],
      "items" => { "type" => "integer" },
    } })
    assert_empty errors_for(schema, { "x" => ["s", 1, 2] })
    assert_includes errors_for(schema, { "x" => [1] }).first, "/x/0: expected string"
    assert_includes errors_for(schema, { "x" => ["s", "t"] }).first, "/x/1: expected integer"
  end

  it "checks object property-count bounds" do
    schema = build_schema(properties: { "x" => {
      "minProperties" => 1, "maxProperties" => 2
    } })
    assert_includes errors_for(schema, { "x" => {} }).first, "needs at least 1"
    assert_includes errors_for(schema, { "x" => { "a" => 1, "b" => 2, "c" => 3 } }).first,
                    "allows at most 2"
  end

  it "reports every missing required property" do
    schema = build_schema(properties: { "x" => { "required" => %w[a b] } })
    errors = errors_for(schema, { "x" => {} })
    assert_includes errors[0], "is missing the required property `a`"
    assert_includes errors[1], "is missing the required property `b`"
  end

  it "rejects properties outside additionalProperties: false" do
    schema = build_schema(properties: { "x" => {
      "properties" => { "a" => true }, "additionalProperties" => false
    } })
    assert_empty errors_for(schema, { "x" => { "a" => 1 } })
    assert_includes errors_for(schema, { "x" => { "b" => 1 } }).first,
                    "/x/b: is not an allowed property"
  end

  it "validates extra properties against an additionalProperties schema" do
    schema = build_schema(properties: { "x" => {
      "additionalProperties" => { "type" => "string" }
    } })
    assert_empty errors_for(schema, { "x" => { "any" => "s" } })
    refute_empty errors_for(schema, { "x" => { "any" => 1 } })
  end

  it "counts patternProperties matches as matched, not additional" do
    schema = build_schema(properties: { "x" => {
      "patternProperties" => { "^n_" => { "type" => "integer" } },
      "additionalProperties" => false,
    } })
    assert_empty errors_for(schema, { "x" => { "n_1" => 1 } })
    refute_empty errors_for(schema, { "x" => { "n_1" => "s" } })
    refute_empty errors_for(schema, { "x" => { "other" => 1 } })
  end

  it "wraps propertyNames violations into one readable error" do
    schema = build_schema(properties: { "x" => {
      "propertyNames" => { "pattern" => "^[a-z]+$" }
    } })
    assert_includes errors_for(schema, { "x" => { "BAD" => 1 } }).first,
                    "is not an allowed property name"
  end

  it "reports a non-string mapping key wherever it appears" do
    schema = build_schema(properties: { "x" => { "type" => "object" } })
    assert_includes errors_for(schema, { "x" => { 1 => "v" } }).first,
                    "has the non-string key 1"
  end

  it "escapes ~ and / in JSON-pointer property tokens" do
    schema = build_schema(properties: { "x" => { "additionalProperties" => false } })
    assert_includes errors_for(schema, { "x" => { "we/ird~key" => 1 } }).first,
                    "/x/we~1ird~0key: is not an allowed property"
  end

  it "truncates oversized values in error messages" do
    truncated = Testsuite::JsonSchema.truncate("x" * 100)
    assert_equal 60, truncated.length
    assert truncated.end_with?("...")
  end
end

describe "JsonSchema combinators" do
  it "allOf applies every branch" do
    schema = build_schema(properties: { "x" => { "allOf" => [
      { "type" => "string" }, { "minLength" => 2 }
    ] } })
    assert_empty errors_for(schema, { "x" => "ab" })
    refute_empty errors_for(schema, { "x" => "a" })
  end

  it "anyOf reports the closest branch when nothing matches" do
    schema = build_schema(properties: { "x" => { "anyOf" => [
      { "type" => "string" },
      { "type" => "object", "required" => ["a"] },
    ] } })
    assert_empty errors_for(schema, { "x" => "s" })
    assert_empty errors_for(schema, { "x" => { "a" => 1 } })
    errors = errors_for(schema, { "x" => 5 })
    assert_includes errors.first, "matches none of the 2 anyOf alternatives"
    assert_includes errors.join("\n"), "the closest one reports:"
  end

  it "oneOf requires exactly one branch" do
    overlapping = build_schema(properties: { "x" => { "oneOf" => [
      { "type" => "string" }, { "minLength" => 1 }
    ] } })
    assert_includes errors_for(overlapping, { "x" => "s" }).first,
                    "matches 2 of the oneOf alternatives, expected exactly 1"
    disjoint = build_schema(properties: { "x" => { "oneOf" => [
      { "type" => "string" }, { "type" => "object" }
    ] } })
    assert_includes errors_for(disjoint, { "x" => 5 }).first,
                    "matches none of the 2 oneOf alternatives"
    assert_empty errors_for(disjoint, { "x" => "s" })
  end

  it "not rejects a matching form and names its required keys" do
    schema = build_schema(properties: { "x" => {
      "not" => { "required" => ["legacy"] }
    } })
    assert_empty errors_for(schema, { "x" => {} })
    assert_includes errors_for(schema, { "x" => { "legacy" => 1 } }).first,
                    "matches a form that is not allowed here (has `legacy`)"
  end

  it "if/then/else takes the matching branch" do
    schema = build_schema(properties: { "x" => {
      "if" => { "required" => ["class"] },
      "then" => { "required" => ["fields"] },
      "else" => { "required" => ["value"] },
    } })
    assert_empty errors_for(schema, { "x" => { "class" => "C", "fields" => {} } })
    assert_includes errors_for(schema, { "x" => { "class" => "C" } }).first,
                    "is missing the required property `fields`"
    assert_includes errors_for(schema, { "x" => {} }).first,
                    "is missing the required property `value`"
  end

  it "a `false` subschema allows nothing, `true` allows anything" do
    schema = build_schema(properties: { "x" => false, "y" => true })
    assert_includes errors_for(schema, { "x" => 1 }).first, "no value is allowed here"
    assert_empty errors_for(schema, { "y" => ["anything", { "at" => "all" }] })
  end
end
