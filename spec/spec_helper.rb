# frozen_string_literal: true

# Shared setup for the validator and generator specs.
#
# Harness: minitest (spec mode), which ships with the Ruby distribution.
# CI runs plain `ruby` with no bundler and no Gemfile, and the validator's
# whole point is running gem-free; the spec suite honours the same constraint.
#
# TESTSUITE_VALIDATOR may point at an alternative copy of validate.rb (used
# for mutation runs: perturb a copy, point the suite at it, and every spec
# guarding the perturbed check must fail). TESTSUITE_GENERATOR does the same
# for generator_spec.rb.

require "minitest/autorun"
require "digest"
require "fileutils"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"

REPO_ROOT = File.expand_path("..", __dir__)
VALIDATOR_PATH = File.expand_path(ENV["TESTSUITE_VALIDATOR"] ||
                                  File.join(REPO_ROOT, "scripts", "validate.rb"))
require VALIDATOR_PATH

module SpecHelpers
  SCHEMA_DIR = File.join(REPO_ROOT, "schema")
  FIXTURES = File.join(__dir__, "fixtures")

  def fixture(name)
    File.join(FIXTURES, name)
  end

  # In-process run of the CLI. Returns [exit_status, output]. A usage or
  # schema error raises Testsuite::Failure here, exactly as documented —
  # the process-level mapping of that raise to exit code 2 is covered by
  # the subprocess specs in validator_cli_spec.rb.
  def run_validator(corpus_root, *flags, schema_dir: SCHEMA_DIR)
    argv = [corpus_root, "--schema", schema_dir, *flags]
    captured = StringIO.new
    original = $stdout
    $stdout = captured
    status = Testsuite::CLI.run(argv)
    [status, captured.string]
  ensure
    $stdout = original
  end

  # The fixture must fail (exit 1) and the report must name the reason.
  def assert_rejects(corpus_root, *flags, message:, schema_dir: SCHEMA_DIR)
    status, out = run_validator(corpus_root, *flags, schema_dir: schema_dir)
    assert_equal 1, status, "expected a validation failure, got:\n#{out}"
    Array(message).each { |m| assert_includes out, m }
    out
  end

  def assert_accepts(corpus_root, *flags, schema_dir: SCHEMA_DIR)
    status, out = run_validator(corpus_root, *flags, schema_dir: schema_dir)
    assert_equal 0, status, "expected a pass, got:\n#{out}"
    out
  end

  # Subprocess run of the same validator file, for the process contract
  # (exit codes, stderr). Returns [exit_status, stdout, stderr].
  def run_validator_process(*argv, chdir: REPO_ROOT)
    out, err, status = Open3.capture3(RbConfig.ruby, VALIDATOR_PATH, *argv,
                                      chdir: chdir)
    [status.exitstatus, out, err]
  end

  # A throwaway corpus for cases a committed fixture cannot express
  # (symlinks, oversized files, mutations).
  def with_corpus(files = {})
    Dir.mktmpdir("testsuite-spec-corpus") do |dir|
      files.each do |relative, content|
        path = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content)
      end
      yield dir
    end
  end

  def with_fixture_copy(name)
    Dir.mktmpdir("testsuite-spec-corpus") do |dir|
      FileUtils.cp_r(File.join(fixture(name), "."), dir)
      yield dir
    end
  end

  # A minimal schema accepted by the validator's own lint, for unit tests of
  # the JSON Schema subset. `properties` merges over the mandatory
  # `schema`-pin so a test can add its own.
  def build_schema(extra = {}, properties: {})
    document = {
      "$schema" => Testsuite::JsonSchema::DIALECT,
      "$id" => "https://example.test/schema/unit/1",
      "properties" => { "schema" => { "const" => "unit/1" } }.merge(properties),
    }.merge(extra)
    Testsuite::JsonSchema::Schema.new(document, "unit-schema")
  end

  def errors_for(schema, instance)
    schema.validate(instance).map(&:to_s)
  end
end

Minitest::Test.include(SpecHelpers)
