# frozen_string_literal: true

# `id` is the join key downstream reporting uses; uniqueness across sibling
# cases is a comparison the schema cannot make, so the validator makes it.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "case ids" do
  it "rejects an id another case already uses" do
    message = '/cases/1/id: reuses "number-integer", which case 0 already uses'
    expect(validation_of(fixture("duplicate-case-ids"), "--no-integrity"))
      .to fail_validation.with_violations(1).reporting(message)
  end

  it "rejects a duplicate id in a cases/2 group too" do
    # The four cross-field checks apply to `cases/2` because the table in
    # scripts/validate.rb registers them for it, not because its shape happens
    # to resemble `cases/1`. Each of these examples is that registration
    # observed from the outside.
    message = '/cases/1/id: reuses "sqrt-unclosed", which case 0 already uses'
    expect(validation_of(fixture("cases2-duplicate-id"), "--no-integrity"))
      .to fail_validation.with_violations(1).reporting(message)
  end
end
