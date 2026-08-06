# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../support/generator"

RSpec.describe CorpusGenerator, ".lockfile_path" do
  it "returns the lockfile when it exists and demands one when it does not" do
    Dir.mktmpdir do |dir|
      expect { described_class.lockfile_path(dir) }
        .to raise_error(described_class::Error) { |error|
          expect(error.message).to include("No Gemfile.lock in #{dir}")
        }
      path = File.join(dir, "Gemfile.lock")
      File.write(path, "")
      expect(described_class.lockfile_path(dir)).to eq(path)
    end
  end
end
