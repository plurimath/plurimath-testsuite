# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../support/generator"

RSpec.describe CorpusGenerator, ".parse_options" do
  it "defaults to no gem override, <repo>/corpus, " \
     "and refusing dirty checkouts" do
    options = described_class.parse_options([])
    expect(options[:gem]).to be_nil
    expect(options[:out]).to eq(File.join(described_class::REPO_ROOT, "corpus"))
    expect(options[:allow_dirty]).to be_falsey
  end

  it "expands --gem and --out to absolute paths" do
    options = described_class.parse_options(["--gem", "/x/gem", "--out",
                                             "relative/out"])
    expect(options[:gem]).to eq("/x/gem")
    expect(options[:out]).to eq(File.expand_path("relative/out"))
  end

  it "recognises --allow-dirty and both help spellings" do
    expect(described_class.parse_options(["--allow-dirty"])[:allow_dirty])
      .to be_truthy
    expect(described_class.parse_options(["--help"])[:help]).to be_truthy
    expect(described_class.parse_options(["-h"])[:help]).to be_truthy
  end

  it "rejects an unknown option" do
    expect { described_class.parse_options(["--bogus"]) }
      .to raise_error(described_class::Error) { |error|
        expect(error.message).to include('unknown option "--bogus"')
      }
  end

  it "rejects a value-taking option left without a value" do
    expect { described_class.parse_options(["--out"]) }
      .to raise_error(described_class::Error) { |error|
        expect(error.message).to include('missing value for option "--out"')
      }
  end

  it "rejects an empty value, which would expand to the working directory" do
    expect { described_class.parse_options(["--gem", ""]) }
      .to raise_error(described_class::Error) { |error|
        expect(error.message).to include('missing value for option "--gem"')
      }
  end
end
