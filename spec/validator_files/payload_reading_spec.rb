# frozen_string_literal: true

# How a payload file is read: portable YAML only, a mapping at the top, and
# bounded nesting.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "payload reading" do
  it "rejects YAML anchors and aliases as non-portable" do
    expect(validation_of(fixture("yaml-anchor-alias"), "--no-integrity"))
      .to fail_validation.with_violations(1).reporting("is not portable YAML")
  end

  it "reports a YAML syntax error as a failure, not a crash" do
    expect(validation_of(fixture("yaml-syntax-error"), "--no-integrity"))
      .to fail_validation.with_violations(1).reporting("is not portable YAML")
  end

  it "rejects a payload that is not a mapping" do
    expect(validation_of(fixture("payload-not-a-mapping"), "--no-integrity"))
      .to fail_validation.with_violations(1)
      .reporting("a payload must be a mapping, got Array")
  end

  # 20k levels: roughly double what overflows the VM stack today, and an
  # order of magnitude cheaper to raise through than a larger constant.
  it "rejects a file too deeply nested to read" do
    deep = "#{'[' * 20_000}#{']' * 20_000}\n"
    with_corpus("asciimath/deep.yaml" => deep) do |dir|
      expect(validation_of(dir, "--no-integrity"))
        .to fail_validation.reporting("nests too deeply")
    end
  end
end
