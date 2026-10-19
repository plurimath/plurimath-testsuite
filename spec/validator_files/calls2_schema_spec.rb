# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "calls/2 schema" do
  def unitsml_payload
    YAML.safe_load_file(File.join(fixture("calls-healthy"),
                                  "asciimath/number-formatting.yaml"))
      .tap do |payload|
      payload["schema"] = "plurimath-corpus/calls/2"
      payload["targets"] = ["mathml"]
      payload["cases"].each do |kase|
        output = kase.fetch("expected").fetch("asciimath")
        kase["expected"] = { "mathml" => output }
        kase["call"] = { "method" => "unitsml", "args" => { "xml" => true } }
      end
    end
  end

  def validate_payload(payload)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "asciimath"))
      File.write(File.join(root, "asciimath/number-formatting.yaml"),
                 YAML.dump(payload))
      validation_of(root, "--no-integrity")
    end
  end

  it "dispatches a measured unitsml call" do
    expect(validate_payload(unitsml_payload)).to pass_validation
  end

  it "retains number_formatter calls in version 2" do
    payload = unitsml_payload
    payload["cases"].first["call"] = {
      "method" => "number_formatter",
      "args" => { "locale" => "en" },
    }
    expect(validate_payload(payload)).to pass_validation
  end

  it "rejects unitsml calls targeting an unmeasured format" do
    payload = unitsml_payload
    payload["targets"] = ["html"]
    payload["cases"].each do |kase|
      kase["expected"] = { "html" => kase.fetch("expected").fetch("mathml") }
    end
    expect(validate_payload(payload)).to fail_validation
  end

  it "keeps unitsml outside the version 1 contract" do
    payload = unitsml_payload
    payload["schema"] = "plurimath-corpus/calls/1"
    expect(validate_payload(payload)).to fail_validation
  end

  it "rejects unmeasured unitsml options" do
    payload = unitsml_payload
    payload["cases"].first["call"]["args"]["xml"] = false
    expect(validate_payload(payload)).to fail_validation
  end

  it "applies cross-field checks to version 2" do
    payload = unitsml_payload
    payload["cases"].first["expected"] = {}
    expect(validate_payload(payload)).to fail_validation
  end
end
