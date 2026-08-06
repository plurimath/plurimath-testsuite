# frozen_string_literal: true

# Shared setup for the validator and generator specs.
#
# Harness: RSpec, installed through the dev-only Gemfile — the spec suite is
# the only thing in this repository that bundles. CI still runs
# scripts/validate.rb with plain `ruby`, no bundler and no gems, and the
# validator's whole point is running gem-free; nothing under scripts/ may
# come to depend on anything the Gemfile drags in.
#
# TESTSUITE_VALIDATOR may point at an alternative copy of validate.rb (used
# for mutation runs: perturb a copy, point the suite at it, and every spec
# guarding the perturbed check must fail). TESTSUITE_GENERATOR does the same
# for generator_spec.rb.

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
  #
  # `violations:` pins the TOTAL count of reported violations — pass 1 for a
  # one-defect fixture. Without it, a fixture that rots and starts failing for
  # a second, unintended reason still passes its spec; a review proved exactly
  # that by adding a second defect to a broken fixture and watching the suite
  # stay green. Violation lines are the report's indented pointer lines.
  #
  # Kept under its minitest name on purpose: the name is the suite's
  # vocabulary (fixture README, mutation notes, review logs all use it), and
  # renaming it buys nothing.
  def assert_rejects(corpus_root, *flags, message:, violations: nil, schema_dir: SCHEMA_DIR)
    status, out = run_validator(corpus_root, *flags, schema_dir: schema_dir)
    expect(status).to eq(1), "expected a validation failure, got:\n#{out}"
    Array(message).each { |m| expect(out).to include(m) }
    unless violations.nil?
      # An indented line opening with a JSON pointer. `/\S*: /` was tried and
      # missed pointers containing spaces (`/bad key: ...`) — reviewer-proven.
      count = out.lines.count { |line| line.match?(%r{\A\s+/.*?: }) }
      expect(count).to eq(violations),
                       "expected exactly #{violations} violation(s), got #{count}:\n#{out}"
    end
    out
  end

  def assert_accepts(corpus_root, *flags, schema_dir: SCHEMA_DIR)
    status, out = run_validator(corpus_root, *flags, schema_dir: schema_dir)
    expect(status).to eq(0), "expected a pass, got:\n#{out}"
    out
  end

  # Subprocess run of the same validator file, for the process contract
  # (exit codes, stderr). Returns [exit_status, stdout, stderr].
  #
  # The subprocess runs outside the suite's bundler environment: `bundle
  # exec` exports RUBYOPT=-rbundler/setup, which would make every child load
  # the bundle — but the validator's contract is plain `ruby
  # scripts/validate.rb`, gem-free, and these specs prove that exact
  # invocation (it is also measurably faster).
  def run_validator_process(*argv, chdir: REPO_ROOT)
    capture = lambda do
      Open3.capture3(RbConfig.ruby, VALIDATOR_PATH, *argv, chdir: chdir)
    end
    out, err, status =
      defined?(Bundler) ? Bundler.with_unbundled_env(&capture) : capture.call
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

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include SpecHelpers
end
