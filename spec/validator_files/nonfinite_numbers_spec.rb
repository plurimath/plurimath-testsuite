# frozen_string_literal: true

# YAML happily reads `.nan` and `.inf`, but JSON cannot write them back, and
# the corpus exists for ordinary JSON Schema consumers.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "non-JSON numbers" do
  it "rejects .nan, .inf, +.inf and -.inf, each at its pointer" do
    result = validation_of(fixture("nonfinite-numbers"), "--no-integrity")
    # the fixture carries all four spellings on purpose
    expect(result).to fail_validation.with_violations(4)
      .reporting("which JSON cannot represent")
    expect(result.output).to include("/nan_value: is NaN")
    expect(result.output).to include("/inf_value: is Infinity")
    expect(result.output).to include("/plus_inf_value: is Infinity")
    expect(result.output).to include("/nested/values/0: is -Infinity")
  end

  it "rejects them before schema evaluation, " \
     "so a NaN never reaches a type check" do
    result = validation_of(fixture("nonfinite-numbers"), "--no-integrity")
    # the fixture carries all four spellings on purpose
    expect(result).to fail_validation.with_violations(4).reporting("is NaN")
    expect(result.output).not_to include("missing the required property"),
                                 "schema evaluation ran on a payload " \
                                 "holding a NaN"
  end

  it "escapes the pointer token even for a non-string key" do
    result = validation_of(fixture("nonfinite-under-nonstring-key"),
                           "--no-integrity")
    expect(result).to fail_validation.with_violations(1).reporting("is NaN")
    expect(result.output).to include('/["a~1b"]: is NaN')
  end
end
