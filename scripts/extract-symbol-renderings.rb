#!/usr/bin/env ruby
# frozen_string_literal: true

# Extract authored expectations only. No Plurimath code is required or evaluated.
# Use a checkout of SOURCE_COMMIT, before its conversion specs were migrated:
# ruby scripts/extract-symbol-renderings.rb RUBY_CHECKOUT OUTPUT.yaml
require_relative "lib/portable_yaml"
require "digest"
require "json"
require "open3"
require "ripper"
require "yaml"

module SymbolRenderingExtractor
  class Error < StandardError; end

  SOURCE_COMMIT = "a6bac8dcf76af4347eb93fa2a7289eb278dd3ffa"
  SCHEMA = "plurimath-fixtures/symbol-renderings/1"
  TARGETS = %w[asciimath latex unicodemath omml mathml html].freeze
  LABELS = %w[AsciiMath LaTeX UnicodeMath OMML MathML HTML].freeze
  EXPECTED_CASES = 1433
  LITERAL = /"(?:[^"\\\n]|\\.)*"/
  LABEL_PATTERN = /^\s*it "matches (AsciiMath|LaTeX|UnicodeMath|OMML|MathML|HTML) string"/
  CLASS_PATTERN = /Plurimath::Math::Symbols::[A-Z]\w*/

  TEMPLATE = <<~'RUBY'
    require "spec_helper"

    RSpec.describe CLASS do
      describe ".initialize" do
        it "returns instance of Symbol NAME" do
          klass = described_class.new
          expect(klass).to be_a(described_class)
        end
      end

      describe "All language conversion specs" do
        subject(:klass) { described_class.new }

        context "Matches all conversion for the Symbol CLASS" do
          it "matches AsciiMath string" do
            expect(klass.to_asciimath).to eq("EXPECTED")
          end

          it "matches LaTeX string" do
            expect(klass.to_latex).to eq("EXPECTED")
          end

          it "matches UnicodeMath string" do
            expect(klass.to_unicodemath).to eq("EXPECTED")
          end

          it "matches OMML string" do
            expect(klass.to_omml_without_math_tag(true)).to eq("EXPECTED")
          end

          it "matches MathML string" do
            string = dump_ox_nodes(klass.to_mathml_without_math_tag(false)).strip
            expect(string).to eq("EXPECTED")
          end

          it "matches HTML string" do
            expect(klass.to_html).to eq("EXPECTED")
          end
        end
      end
    end
  RUBY

  module_function

  def interpolated?(tree)
    return false unless tree.is_a?(Array)
    return true if %i[string_embexpr string_dvar].include?(tree.first)

    tree.any? { |child| interpolated?(child) }
  end

  def extract_case(source, path)
    tree = Ripper.sexp(source)
    raise Error, "#{path}: invalid Ruby syntax or interpolation" if !tree || interpolated?(tree)

    literals = source.scan(/\.to eq\((#{LITERAL})\)/).flatten
    raise Error, "#{path}: expected six literal outputs" unless literals.length == TARGETS.length

    classes = source.scan(CLASS_PATTERN).uniq
    raise Error, "#{path}: expected one symbol class" unless classes.length == 1

    name = classes.first
    normalized = source.gsub(name, "CLASS")
      .sub(/instance of Symbol [^"\n]*/, "instance of Symbol NAME")
      .gsub(/\.to eq\(#{LITERAL}\)/, '.to eq("EXPECTED")')
      .sub("klass.to_asciimath(options: {})", "klass.to_asciimath")
      .sub("klass.to_mathml_without_math_tag(true)", "klass.to_mathml_without_math_tag(false)")
    unless normalized.sub(/\n+\z/, "\n") == TEMPLATE
      raise Error, "#{path}: unsupported symbol conversion template"
    end

    {
      "id" => File.basename(path, "_spec.rb"),
      "class" => name.delete_prefix("Plurimath::"),
      "mathml_intent" => source.include?("klass.to_mathml_without_math_tag(true)"),
      "asciimath_explicit_empty_options" => source.include?("klass.to_asciimath(options: {})"),
      "expected" => TARGETS.zip(literals.map { |literal| JSON.parse(literal) }).to_h,
      "source" => { "path" => path, "sha256" => Digest::SHA256.hexdigest(source) },
    }
  rescue JSON::ParserError => e
    raise Error, "#{path}: expected literal is outside the safe JSON subset: #{e.message}"
  end

  def extract(root)
    symbol_root = File.join(root, "spec/plurimath/math/symbols")
    files = Dir.glob(File.join(symbol_root, "**/*_spec.rb"))
    raise Error, "no symbol specs under #{symbol_root}" if files.empty?

    listing, status = Open3.capture2e("git", "-C", root, "ls-tree", "-r", SOURCE_COMMIT,
                                     "--", "spec/plurimath/math/symbols")
    raise Error, "cannot read pinned source tree: #{listing}" unless status.success?

    blobs = listing.lines.to_h do |line|
      metadata, path = line.chomp.split("\t", 2)
      [path, metadata.split.last]
    end

    cases = files.filter_map do |file|
      source = File.read(file, encoding: "UTF-8")
      labels = source.scan(LABEL_PATTERN).flatten
      next if labels.empty?

      path = file.delete_prefix("#{File.expand_path(root)}/")
      raise Error, "#{path}: incomplete or duplicate conversion targets" unless labels == LABELS

      blob = Digest::SHA1.hexdigest("blob #{source.bytesize}\0#{source}")
      raise Error, "#{path}: differs from pinned source commit" unless blobs[path] == blob

      extract_case(source, path)
    end
    unless cases.length == EXPECTED_CASES && cases.map { |row| row.fetch("id") }.uniq.length == cases.length &&
        cases.map { |row| row.fetch("class") }.uniq.length == cases.length
      raise Error, "expected #{EXPECTED_CASES} distinct symbol cases, got #{cases.length}"
    end

    {
      "schema" => SCHEMA,
      "provenance" => {
        "repository" => "https://github.com/plurimath/plurimath",
        "ruby_commit" => SOURCE_COMMIT,
      },
      "targets" => TARGETS,
      "cases" => cases,
    }
  end
end

if $PROGRAM_NAME == __FILE__
  unless ARGV.length == 2
    warn "usage: ruby scripts/extract-symbol-renderings.rb RUBY_CHECKOUT OUTPUT.yaml"
    exit 1
  end

  begin
    dataset = SymbolRenderingExtractor.extract(File.expand_path(ARGV.fetch(0)))
    File.write(ARGV.fetch(1), PortableYaml.dump(dataset), encoding: "UTF-8")
    puts "Extracted #{dataset.fetch('cases').length} symbols / #{dataset.fetch('cases').length * 6} authored outputs"
  rescue SymbolRenderingExtractor::Error, SystemCallError => e
    warn e.message
    exit 1
  end
end
