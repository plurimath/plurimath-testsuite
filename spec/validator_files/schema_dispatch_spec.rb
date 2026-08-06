# frozen_string_literal: true

# Each payload names its own schema in a top-level `schema:` key; dispatch is
# the schema whose declaration constraint that value satisfies, and exactly
# one must match.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "schema dispatch" do
  it "rejects a payload with no schema key" do
    message = "/schema: missing; every payload declares the schema it follows"
    expect(validation_of(fixture("schema-key-missing"), "--no-integrity"))
      .to fail_validation.with_violations(1).reporting(message)
  end

  it "rejects a schema key that is not a string, naming what arrived" do
    expect(validation_of(fixture("schema-key-nonstring"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("must name a schema as a string, got integer 5")
  end

  it "rejects a declaration no schema claims" do
    expect(validation_of(fixture("schema-unclaimed"), "--no-integrity"))
      .to fail_validation.with_violations(1).reporting("no schema in")
  end

  it "rejects a declaration claimed by more than one schema" do
    expect(validation_of(fixture("schema-ambiguous"), "--no-integrity",
                         schema_dir: fixture("schemas/ambiguous")))
      .to fail_validation.with_violations(1)
      .reporting("is claimed by 2 schemas")
  end

  it "refuses to load two schemas claiming the same declaration" do
    expect do
      validation_of(fixture("healthy-minimal"),
                    schema_dir: fixture("schemas/duplicate-claim"))
    end.to raise_error(Testsuite::Failure) { |error|
      expect(error.message)
        .to include("two schemas claim plurimath-corpus/asciimath/1")
    }
  end

  it "refuses a schema file that is not valid JSON" do
    expect do
      validation_of(fixture("healthy-minimal"),
                    schema_dir: fixture("schemas/invalid-json"))
    end.to raise_error(Testsuite::Failure) { |error|
      expect(error.message).to include("invalid JSON")
    }
  end

  it "refuses an empty schema directory" do
    Dir.mktmpdir do |empty|
      expect do
        validation_of(fixture("healthy-minimal"), schema_dir: empty)
      end.to raise_error(Testsuite::Failure) { |error|
        expect(error.message).to include("no schemas in")
      }
    end
  end
end
