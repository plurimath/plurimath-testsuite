# frozen_string_literal: true

# What the cases/2 schema rejects. `cases/2` differs from `cases/1` in one
# place only: a target carries an OUTCOME — `output:` or `error:` — instead of
# a string, so that an input the gem accepts but renders to only SOME targets
# can be recorded at all. Every example below is about that discrimination
# holding: two states, exhaustive and exclusive, with no third.
#
# Each broken fixture under spec/fixtures/ carries exactly one defect;
# spec/fixtures/README.md names the check each one exists for. Runs with
# --no-integrity so that defect is the only failure.
#
# The healthy case comes first on purpose: a negative test whose fixture was
# broken for some other reason proves nothing, and every fixture below is that
# same payload with one thing changed.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "cases/2 schema" do
  it "accepts a healthy payload, so the rest fail only on their defect" do
    expect(validation_of(fixture("cases2-healthy"), "--no-integrity"))
      .to pass_validation
  end

  # The three below are the discrimination itself. `oneOf` reports the
  # container plus its closest branch, so each is 2 violations for 1 defect.
  it "rejects an outcome that both renders and refuses" do
    # Without `additionalProperties: false` inside the branches, this would
    # satisfy the `output` branch AND the `error` branch, and a consumer could
    # pick whichever one its implementation happened to produce.
    expect(validation_of(fixture("cases2-outcome-both"), "--no-integrity"))
      .to fail_validation.with_violations(2)
      .reporting("/cases/0/expected/asciimath",
                 "matches none of the 2 oneOf alternatives",
                 "/cases/0/expected/asciimath/error: " \
                 "is not an allowed property")
  end

  it "rejects an outcome that neither renders nor refuses" do
    # The empty outcome is the third state the discrimination must not have:
    # a target that was recorded, said nothing, and asserts nothing.
    expect(validation_of(fixture("cases2-outcome-empty"), "--no-integrity"))
      .to fail_validation.with_violations(2)
      .reporting("matches none of the 2 oneOf alternatives",
                 "is missing the required property `output`")
  end

  it "rejects the bare string a cases/1 case writes at this position" do
    # A `cases/1` case pasted into a `cases/2` payload must not validate: it
    # would silently mean "renders", and the whole point of the kind is that
    # rendering is one of two things a target can do, said explicitly.
    expect(validation_of(fixture("cases2-outcome-bare-string"),
                         "--no-integrity"))
      .to fail_validation.with_violations(2)
      .reporting("/cases/0/expected/asciimath: matches none of the 2 oneOf",
                 "/cases/0/expected/asciimath: expected object, got string")
  end

  it "rejects a key smuggled in beside an outcome's output" do
    expect(validation_of(fixture("cases2-outcome-extra-key"), "--no-integrity"))
      .to fail_validation.with_violations(2)
      .reporting("/cases/0/expected/asciimath/note: is not an allowed property")
  end

  it "rejects an error category the schema does not know" do
    # As in `rejections/1`, the categories are an enum rather than a free
    # string because they are the join key an implementation asserts on; a
    # typo would otherwise become a category nothing ever matches, and every
    # port would pass by never producing it.
    expect(validation_of(fixture("cases2-unknown-error-category"),
                         "--no-integrity"))
      .to fail_validation.with_violations(2)
      .reporting("/cases/0/expected/unicodemath/error/category",
                 '"render_error" is not one of "parse_error"')
  end

  it "rejects a failure offset on an outcome that has no position" do
    # `rejections/1` records `error.index`, an offset into `preprocessed`.
    # Here there is nothing for one to point at: the input parsed, and the
    # refusal happened downstream of the text while rendering the model.
    expect(validation_of(fixture("cases2-error-with-index"), "--no-integrity"))
      .to fail_validation.with_violations(2)
      .reporting("/cases/0/expected/unicodemath/error/index",
                 "is not an allowed property")
  end
end
