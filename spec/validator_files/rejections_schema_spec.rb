# frozen_string_literal: true

# What the rejections schema rejects. Each broken fixture under spec/fixtures/
# carries exactly one defect; spec/fixtures/README.md names the check each one
# exists for. Runs with --no-integrity so that defect is the only failure.
#
# The healthy case comes first on purpose: a negative test whose fixture was
# broken for some other reason proves nothing, and every fixture below is that
# same payload with one thing changed.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "rejections schema" do
  it "accepts a healthy payload, so the rest fail only on their defect" do
    expect(validation_of(fixture("rejections-healthy"),
                         "--no-integrity")).to pass_validation
  end

  it "rejects a case with no error block, the whole point of the record" do
    expect(validation_of(fixture("rejections-missing-error"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("is missing the required property `error`")
  end

  it "rejects an error category the schema does not know" do
    # The categories are an enum rather than a free string because they are the
    # join key an implementation asserts on; a typo would otherwise become a
    # category nothing ever matches, and every port would pass by never
    # producing it.
    expect(validation_of(fixture("rejections-unknown-category"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/error/category")
  end

  it "rejects a rejection that carries an expected rendering" do
    # An input that never parsed has nothing to render. Allowing `expected`
    # here would let a case be half positive and half negative, and an
    # implementation could satisfy it by rendering rather than refusing.
    expect(validation_of(fixture("rejections-with-expected"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/expected: is not an allowed property")
  end

  it "rejects an empty input, since there must be something to refuse" do
    expect(validation_of(fixture("rejections-empty-input"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/input")
  end

  it "rejects a negative failure offset" do
    expect(validation_of(fixture("rejections-negative-index"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/error/index")
  end
end
