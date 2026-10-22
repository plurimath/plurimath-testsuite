# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../scripts/extract-renderer-expectations"

RSpec.describe RendererExpectations::Extractor, "pinned source dependencies" do
  around do |example|
    previous = ENV["RENDERER_SOURCE_REVISION"]
    ENV["RENDERER_SOURCE_REVISION"] = "a" * 40
    example.run
  ensure
    ENV["RENDERER_SOURCE_REVISION"] = previous
  end

  def with_pinned_sources
    Dir.mktmpdir("pinned-renderer-source") do |root|
      prefix = "spec/plurimath/fixtures/formula_modules/"
      sources = {
        "#{prefix}expected_values.rb" => "module ExpectedValues; EX_001 = nil; end",
        "#{prefix}line_break_values.rb" => "module LineBreakValues; EX_001 = nil; end",
        "#{prefix}unicode_math_transform_values.rb" => "module UnicodeMathTransformValues; EXAMPLE_001 = Plurimath::Math::Number.new(\"12\"); end",
        "#{prefix}unicode_math_string_values.rb" => "module UnicodeMathStringValues; EXAMPLE_001 = \"12\"; end",
        "spec/input.xml" => "<math/>",
      }
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2) do |*arguments|
        path = arguments.last.delete_prefix("#{ENV.fetch('RENDERER_SOURCE_REVISION')}:")
        expect(arguments[0...-1]).to eq(["git", "-C", root, "show"])
        [sources.fetch(path), status]
      end
      yield described_class.new(root), root
    end
  end

  it "exports Unicode rows without requiring deleted worktree constants" do
    with_pinned_sources do |extractor, root|
      expect(Dir.children(root)).to be_empty
      extractor.instance_variable_set(:@relative, "spec/plurimath/math/formula/unicodemath_spec.rb")
      rows = extractor.unicode_rows(1)
      expect(rows.length).to eq(1)
      expect(rows.first.fetch("expected")).to eq("12")
      expect(rows.first.dig("input", "recipe", "class")).to eq("Math::Number")
    end
  end

  it "reads other tracked dependencies through the same pinned revision" do
    with_pinned_sources do |extractor, root|
      expect(Dir.children(root)).to be_empty
      expect(extractor.source_text("spec/input.xml")).to eq("<math/>")
      expect { extractor.source_text("../outside") }.to raise_error(RendererExpectations::Unsupported, /outside spec/)
    end
  end
end
