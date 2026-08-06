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
end
