# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../scripts/validate-fixtures"

RSpec.describe PortableFixtures do
  def with_authored_fixture
    Dir.mktmpdir("authored-fixture-check") do |directory|
      FileUtils.mkdir_p(File.join(directory, "schema"))
      FileUtils.mkdir_p(File.join(directory, "fixtures"))
      FileUtils.cp(File.join(REPO_ROOT, "schema/cli-conversions.json"), File.join(directory, "schema"))
      payload = YAML.safe_load(File.read(File.join(REPO_ROOT, "fixtures/cli-conversions.yaml")))
      path = File.join(directory, "fixtures/cli-conversions.yaml")
      yield directory, path, payload
    end
  end

  before { stub_const("PortableFixtures::FILES", ["cli-conversions"]) }

  it "validates the declared authored schema without loading a math library" do
    with_authored_fixture do |root, path, payload|
      File.write(path, YAML.dump(payload))
      expect { described_class.validate!(root: root) }.to output(/1 authored fixture payloads, 3 cases validated/).to_stdout
    end
  end

  it "rejects absent and additional fixture files" do
    with_authored_fixture do |root, path, payload|
      expect { described_class.validate!(root: root) }.to raise_error(Testsuite::Failure, /inventory differs/)
      File.write(path, YAML.dump(payload))
      File.write(File.join(root, "fixtures/extra.yaml"), "{}")
      expect { described_class.validate!(root: root) }.to raise_error(Testsuite::Failure, /inventory differs/)
    end
  end

  it "rejects duplicate IDs even when every row matches its schema" do
    with_authored_fixture do |root, path, payload|
      payload.fetch("cases")[1]["id"] = payload.fetch("cases").first.fetch("id")
      File.write(path, YAML.dump(payload))
      expect { described_class.validate!(root: root) }.to raise_error(Testsuite::Failure, /unique and nonempty/)
    end
  end

  it "rejects unknown declarations and empty cases" do
    with_authored_fixture do |root, path, payload|
      payload["schema"] = "plurimath-fixtures/unknown/1"
      File.write(path, YAML.dump(payload))
      expect { described_class.validate!(root: root) }.to raise_error(Testsuite::Failure, /exactly one declared schema/)
      payload["schema"] = "plurimath-fixtures/cli-conversions/1"
      payload["cases"] = []
      File.write(path, YAML.dump(payload))
      expect { described_class.validate!(root: root) }.to raise_error(Testsuite::Failure, /needs at least 1/)
    end
  end

  it "rejects YAML aliases and non-JSON numeric values" do
    with_authored_fixture do |root, path, payload|
      File.write(path, "schema: &s example\ncases: *s\n")
      expect { described_class.validate!(root: root) }.to raise_error(Testsuite::Failure)
      payload.fetch("cases").first["stdout"] = Float::NAN
      File.write(path, YAML.dump(payload))
      expect { described_class.validate!(root: root) }.to raise_error(Testsuite::Failure)
    end
  end
end
