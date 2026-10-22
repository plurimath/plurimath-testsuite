#!/usr/bin/env ruby
# frozen_string_literal: true

# Authored expectations are separate from oracle-generated corpus snapshots.
# Validate their declared closed schemas without loading a math implementation.
require_relative "validate"

module PortableFixtures
  ROOT = File.expand_path("..", __dir__)
  FILES = %w[cli-conversions facade-expectations formatter-expectations grammar-expectations parser-expectations renderer-expectations symbol-renderings xml-parser-expectations unicode-expectations].freeze

  module_function

  def validate!(root: ROOT)
    directory = File.join(root, "fixtures")
    expected = FILES.map { |name| "#{name}.yaml" }.sort
    actual = Dir.children(directory).sort
    raise Testsuite::Failure, "fixture inventory differs: #{actual.inspect}" unless actual == expected

    schemas = Dir.glob(File.join(root, "schema/*.json")).map do |path|
      Testsuite::JsonSchema::Schema.new(JSON.parse(File.read(path)), path)
    end
    count = 0
    expected.each do |name|
      path = File.join(directory, name)
      payload = YAML.safe_load(File.read(path), aliases: false)
      raise Testsuite::Failure, "#{name}: fixture must be a mapping" unless payload.is_a?(Hash)
      unless payload["schema"].is_a?(String)
        raise Testsuite::Failure, "#{name}: fixture must declare its schema"
      end
      # YAML also accepts non-JSON floats such as .nan; portable data does not.
      JSON.generate(payload, allow_nan: false, max_nesting: false)

      matched = schemas.select { |schema| schema.accepts_declaration?(payload["schema"]) }
      raise Testsuite::Failure, "#{name}: expected exactly one declared schema" unless matched.one?
      schema = matched.first
      errors = schema.validate(payload)
      unless errors.empty?
        raise Testsuite::Failure, "#{name}:\n#{errors.map(&:to_s).join("\n")}"
      end
      unless payload.fetch("schema") == "plurimath-fixtures/#{File.basename(name, '.yaml')}/1"
        raise Testsuite::Failure, "#{name}: schema and filename differ"
      end
      rows = payload.fetch("cases")
      ids = rows.map { |row| row.fetch("id") }
      if ids.empty? || ids.uniq.length != ids.length
        raise Testsuite::Failure, "#{name}: fixture IDs must be unique and nonempty"
      end
      if name == "symbol-renderings.yaml"
        classes = rows.map { |row| row.fetch("class") }
        raise Testsuite::Failure, "#{name}: duplicate symbol class" unless classes.uniq.length == classes.length
      end
      count += rows.length
      puts "OK #{name}: #{rows.length} cases"
    end
    puts "#{expected.length} authored fixture payloads, #{count} cases validated"
    count
  rescue Errno::ENOENT, JSON::ParserError, JSON::GeneratorError, Psych::Exception => error
    raise Testsuite::Failure, error.message
  end

  def main
    validate!
    0
  rescue Testsuite::Failure => error
    warn error.message
    1
  end
end

exit PortableFixtures.main if $PROGRAM_NAME == __FILE__
