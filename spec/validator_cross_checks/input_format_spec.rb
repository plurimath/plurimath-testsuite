# frozen_string_literal: true

# A group's input format is written down four times: in the `schema` value's
# middle segment, in `input_format`, in the directory the file sits in, and
# in every case. One fact, four spellings — all four must agree.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "input_format agreement" do
  it "rejects an input_format that disagrees with the schema declaration" do
    expect(validation_of(fixture("format-vs-schema-segment"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/input_format", "whose middle segment is the input format")
  end

  it "rejects a group filed in the wrong directory" do
    expect(validation_of(fixture("format-vs-directory"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting('/input_format: is "asciimath", but the file sits in mathml/')
  end

  it "rejects a case that switches format mid-group" do
    expect(validation_of(fixture("format-vs-case"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/input_format",
                 "a case does not switch formats mid-group")
  end

  it "rejects a cases/2 input_format disagreeing with its declaration" do
    expect(validation_of(fixture("cases2-format-vs-schema-segment"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/input_format",
                 "`schema: plurimath-corpus/asciimath/2`")
  end

  it "rejects a cases/2 group filed in the wrong directory" do
    expect(validation_of(fixture("cases2-format-vs-directory"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting('/input_format: is "asciimath", but the file sits in mathml/')
  end

  it "rejects a cases/2 case that switches format mid-group" do
    expect(validation_of(fixture("cases2-case-format-drift"),
                         "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("/cases/0/input_format",
                 "a case does not switch formats mid-group")
  end
end
