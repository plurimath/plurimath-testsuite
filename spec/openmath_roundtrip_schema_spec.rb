# frozen_string_literal: true

RSpec.describe "OpenMath roundtrip schema" do
  let(:schema) do
    Testsuite::JsonSchema::Schema.new(
      JSON.parse(File.read(File.join(REPO_ROOT, "schema/stage-roundtrip.json"))),
      "stage-roundtrip")
  end
  let(:payload) do
    YAML.safe_load_file(fixture("stages/healthy/stages/roundtrip/generations/000001/payloads/smoke.yaml"))
  end

  it "allows OpenMath as a source" do
    payload["cases"].first["source"]["language"] = "openmath"
    expect(schema.validate(payload)).to be_empty
  end

  it "allows OpenMath as a target alongside existing targets" do
    payload["cases"].first["expected"]["openmath"] = { "refusal" => { "category" => "unsupported_expression" } }
    expect(schema.validate(payload)).to be_empty
  end

  it "rejects an unknown source notation" do
    payload["cases"].first["source"]["language"] = "unknown"
    expect(schema.validate(payload)).not_to be_empty
  end

  it "rejects an unknown target notation" do
    payload["cases"].first["expected"]["unknown"] = { "output" => "x", "lossless" => true }
    expect(schema.validate(payload)).not_to be_empty
  end
end
