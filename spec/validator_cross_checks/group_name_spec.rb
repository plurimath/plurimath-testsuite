# frozen_string_literal: true

# The schema says `group` matches the file name without its extension; a
# schema cannot see the file name, so scripts/validate.rb keeps the promise.
# Runs with --no-integrity so the fixture's one defect is the only failure.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "group and file name" do
  it "rejects a group that is not the file's stem" do
    expect(validation_of(fixture("group-vs-filename"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting('/group: is "numbers", but the file is named misnamed.yaml')
  end
end
