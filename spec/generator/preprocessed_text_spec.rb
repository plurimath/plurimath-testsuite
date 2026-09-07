# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../support/generator"

RSpec.describe CorpusGenerator, ".preprocessed_text" do
  # A Format carrying only the two fields this method reads. Built here rather
  # than taken from FORMATS so the nil case can exist at all: every shipped
  # format declares a preprocessing pass.
  def format_with(preprocess)
    CorpusGenerator::Format.new(
      name: "probe", label: "Probe", targets: ["latex"],
      preprocess: preprocess, parse_tree: ->(text) { text },
      groups: [], rejection_candidates: [], partial_candidates: []
    )
  end

  it "records what the format's own preprocessing pass returns" do
    format = format_with(->(input) { input.tr("{", "L") })
    expect(described_class.preprocessed_text(format, "{a")).to eq("La")
  end

  it "refuses a format that declares no preprocessing pass" do
    # `preprocessed` is required by cases/1, cases/2 and rejections/1 alike,
    # so there is no payload that can omit it and no honest value to invent.
    expect { described_class.preprocessed_text(format_with(nil), "a") }
      .to raise_error(CorpusGenerator::Error, /no preprocessing pass/)
  end
end
