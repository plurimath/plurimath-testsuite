# frozen_string_literal: true

# Load-time checks on the schemas themselves: a schema this validator cannot
# fully enforce must be rejected when it loads, never quietly half-applied.

require_relative "../spec_helper"

RSpec.describe Testsuite::JsonSchema::Schema, "schema linting" do
  it "rejects a schema that is not an object" do
    expect { described_class.new(["not", "a", "schema"], "lint") }
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
    expect { described_class.new(document, "lint") }
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("must pin the payload kind")
      }
  end

  it "rejects any keyword outside the implemented whitelist" do
    expect { build_schema({ "contains" => { "type" => "string" } }) }
      .to raise_error(Testsuite::Failure) { |error|
        message = "uses `contains`, which this validator does not implement"
        expect(error.message).to include(message)
      }
  end

  it "rejects unimplemented keywords in nested subschemas too" do
    expect do
      build_schema(properties: { "x" => { "unevaluatedProperties" => false } })
    end
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message)
          .to include("#/properties/x uses `unevaluatedProperties`")
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
        expect(error.message)
          .to include("only local #/... references are supported")
      }
  end

  it "rejects a $ref that resolves to nothing" do
    expect do
      build_schema(properties: { "x" => { "$ref" => "#/$defs/missing" } })
    end
      .to raise_error(Testsuite::Failure) { |error|
        expect(error.message)
          .to include("references #/$defs/missing, which does not exist")
      }
  end

  it "unescapes ~1 and ~0 in $ref pointer tokens" do
    schema = build_schema(
      { "$defs" => { "a/b" => { "type" => "integer" } } },
      properties: { "x" => { "$ref" => "#/$defs/a~1b" } },
    )
    expect(errors_for(schema, { "x" => 3 })).to be_empty
    expect(errors_for(schema,
                      { "x" => "s" }).first).to include("expected integer")
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
    expect(build_schema).to be_accepts_declaration("unit/1")
    expect(build_schema).not_to be_accepts_declaration("other/1")
    expect(build_schema).not_to be_accepts_declaration(5)

    patterned = build_schema(
      properties: { "schema" => { "pattern" => "^unit/(a|b)/1$" } },
    )
    expect(patterned).to be_accepts_declaration("unit/a/1")
    expect(patterned).not_to be_accepts_declaration("unit/c/1")
  end
end
