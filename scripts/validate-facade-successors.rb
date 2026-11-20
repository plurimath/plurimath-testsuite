# frozen_string_literal: true

require "digest"
require "json"
require "yaml"
require_relative "validate"

# A separately selected facade contract. Loading this module never selects a
# profile or changes the legacy fixtures or the immutable stage generations.
module FacadeSuccessors
  class Error < StandardError; end
  module_function

  def load(root, profile)
    raise Error, "invalid facade profile" unless /\A[a-z0-9]+(?:-[a-z0-9]+)*-v[1-9][0-9]*\z/.match?(profile)

    path = File.join(root, "contracts/facade", "#{profile}.json")
    data = JSON.parse(File.read(path))
    schema = JSON.parse(File.read(File.join(root, "schema/facade-successors.json")))
    errors = Testsuite::JsonSchema::Schema.new(schema, "facade-successors.json").validate(data)
    raise Error, errors.map(&:to_s).join("\n") unless errors.empty?
    raise Error, "facade profile differs from filename" unless data.fetch("profile") == profile

    ids = data.fetch("cases").map { |row| row.fetch("id") }
    sources = data.fetch("cases").map { |row| row.fetch("source").values_at("path", "id") }
    raise Error, "duplicate facade successor or source" unless ids.uniq == ids && sources.uniq == sources

    # Several authored rows share one large immutable fixture file. Read one
    # consistent snapshot per path, retaining each entry's checksum guard.
    source_files = {}
    data.fetch("cases").each do |entry|
      source = entry.fetch("source")
      source_path = File.join(root, source.fetch("path"))
      file = source_files[source_path] ||= { text: File.binread(source_path) }
      file[:sha256] ||= Digest::SHA256.hexdigest(file.fetch(:text))
      raise Error, "source checksum differs: #{source_path}" unless file.fetch(:sha256) == source.fetch("sha256")
      rows = file[:rows] ||= YAML.safe_load(file.fetch(:text), aliases: false).fetch("cases")
      matches = rows.select { |row| row.fetch("id") == source.fetch("id") }
      raise Error, "expected exactly one frozen source row" unless matches.length == 1
      raise Error, "successor ID must name its source and profile" unless entry.fetch("id") == "#{source.fetch('id')}-#{profile}"

      apply(matches.first, entry)
    end
    data
  end

  def apply(row, entry)
    copy = JSON.parse(JSON.generate(row))
    copy["id"] = entry.fetch("id")
    if entry.key?("expected")
      raise Error, "output successor must reference a corpus row" unless entry.fetch("source").fetch("path").start_with?("corpus/")

      entry.fetch("expected").each do |target, value|
        previous = copy.fetch("expected").fetch(target)
        raise Error, "successor cannot change an outcome's representation" unless previous.is_a?(String) == value.is_a?(String) || (previous.is_a?(String) && value.is_a?(Hash) && value.key?("error"))
        raise Error, "successor must change the named expectation" if previous == value

        copy.fetch("expected")[target] = value
      end
    elsif entry.key?("renderer_assertions")
      apply_renderer_assertions(copy, entry)
    else
      raise Error, "refusal successor must reference renderer fixtures" unless entry.fetch("source").fetch("path") == "fixtures/renderer-expectations.yaml"

      steps = copy.fetch("program").fetch("steps")
      entry.fetch("refusals").each do |refusal|
        indexes = steps.each_index.select { |i| steps[i]["kind"] == "render" && steps[i]["save"] == refusal.fetch("render_slot") }
        raise Error, "expected exactly one renderer operation" unless indexes.length == 1

        index = indexes.first
        render = steps.fetch(index)
        assertion = steps.fetch(index + 1)
        unless assertion["kind"] == "assert" && assertion["source"] == render.fetch("save") && assertion["assertion_line"] == refusal.fetch("assertion_line")
          raise Error, "refusal must replace the operation's original assertion"
        end
        # Retain every other source operation/assertion, including MathML.
        steps[index, 2] = [{ "kind" => "assert_refusal", "source" => render.fetch("source"),
                            "operation" => render.fetch("operation"),
                            "assertion_line" => refusal.fetch("assertion_line"),
                            "error_class" => refusal.fetch("error_class"), "message" => refusal.fetch("message") }]
      end
    end
    copy
  end

  def apply_renderer_assertions(copy, entry)
    unless entry.fetch("source").fetch("path") == "fixtures/renderer-expectations.yaml"
      raise Error, "renderer successor must reference renderer fixtures"
    end

    lines = entry.fetch("renderer_assertions").map { |item| item.fetch("assertion_line") }
    raise Error, "duplicate renderer assertion line" unless lines.uniq == lines

    entry.fetch("renderer_assertions").each do |replacement|
      line = replacement.fetch("assertion_line")
      if copy.key?("program")
        steps = copy.fetch("program").fetch("steps")
        matches = steps.select { |step| step["kind"] == "assert" && step["assertion_line"] == line }
        raise Error, "expected exactly one original assertion" unless matches.length == 1

        assertion = matches.first
        previous = assertion["expected"]
        if assertion.key?("expected_slot")
          build = steps.find { |step| step["kind"] == "build" && step["save"] == assertion.fetch("expected_slot") }
          recipe = build && build.fetch("recipe")
          recipe = recipe.fetch("value") while recipe && recipe["kind"] == "memo"
          raise Error, "renderer expected slot must build a literal string" unless recipe && recipe["kind"] == "literal"

          previous = recipe.fetch("value")
        end
      else
        raise Error, "renderer assertion line differs from source" unless copy.fetch("source").fetch("assertion_line") == line
        raise Error, "renderer observations need their own successor" if copy.key?("observations")

        assertion = copy
        previous = copy.fetch("expected")
      end
      unless %w[eq eql be_xml_equivalent_to].include?(assertion.fetch("comparison")) && previous.is_a?(String)
        raise Error, "renderer successor requires a string equality assertion"
      end
      raise Error, "successor must change the named expectation" if previous == replacement.fetch("expected")

      assertion.delete("expected_slot")
      assertion["expected"] = replacement.fetch("expected")
    end
  end

  def select(data, path, rows)
    entries = data.fetch("cases").select { |entry| entry.fetch("source").fetch("path") == path }
    entries.each do |entry|
      unless rows.count { |row| row.fetch("id") == entry.fetch("source").fetch("id") } == 1
        raise Error, "selected facade source is missing or duplicated"
      end
    end
    rows.map do |row|
      entry = entries.find { |item| item.fetch("source").fetch("id") == row.fetch("id") }
      entry ? apply(row, entry) : row
    end
  end

  def validate_base!(root, base)
    require "open3"
    paths = %w[corpus fixtures provenance stages generations contracts/facade]
    output, error, status = Open3.capture3("git", "-C", root, "diff", "--name-only", "--diff-filter=CDMRTUXB", base, "--", *paths)
    raise Error, error unless status.success?
    raise Error, "frozen payloads or profiles changed:\n#{output}" unless output.empty?
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    root = File.expand_path("..", __dir__)
    if ARGV.any?
      abort "usage: #{$PROGRAM_NAME} [--base SHA]" unless ARGV.length == 2 && ARGV.first == "--base"
      FacadeSuccessors.validate_base!(root, ARGV.last)
    end
    paths = Dir.glob(File.join(root, "contracts/facade/*.json"))
    raise FacadeSuccessors::Error, "no facade successor profiles" if paths.empty?

    paths.each do |path|
      data = FacadeSuccessors.load(root, File.basename(path, ".json"))
      puts "#{data.fetch('profile')}: #{data.fetch('cases').length} successors; frozen source hashes verified"
    end
  rescue FacadeSuccessors::Error, Testsuite::Failure, KeyError, JSON::ParserError => e
    warn e.message
    exit 1
  end
end
