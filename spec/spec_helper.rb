# frozen_string_literal: true

# Shared setup for the validator and generator specs.
#
# The spec suite is the only thing in this repository that bundles. CI runs
# scripts/validate.rb with plain `ruby`, no bundler and no gems, and the
# validator's whole point is running gem-free; nothing under scripts/ may
# come to depend on anything the Gemfile drags in.
#
# TESTSUITE_VALIDATOR may point at an alternative copy of validate.rb (used
# for mutation runs: perturb a copy, point the suite at it, and every spec
# guarding the perturbed check must fail). TESTSUITE_GENERATOR does the same
# for the generator (loaded by spec/support/generator.rb).

require "digest"
require "fileutils"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"

REPO_ROOT = File.expand_path("..", __dir__)
VALIDATOR_PATH = File.expand_path(ENV["TESTSUITE_VALIDATOR"] ||
                                  File.join(REPO_ROOT, "scripts",
                                            "validate.rb"))
require VALIDATOR_PATH

module SpecHelpers
  SCHEMA_DIR = File.join(REPO_ROOT, "schema")
  FIXTURES = File.join(__dir__, "fixtures")

  def fixture(name)
    File.join(FIXTURES, name)
  end

  # Subprocess run of the same validator file, for the process contract
  # (exit codes, stderr). Returns [exit_status, stdout, stderr].
  #
  # The child runs with `--disable-gems`, and that flag IS the gem-free proof.
  # Unbundling alone is not one: `with_unbundled_env` strips Bundler, but
  # RubyGems still resolves installed gems, so a validator that quietly grew a
  # `require "rspec"` passed the whole suite — review-proven. With gems off,
  # that mutant dies with LoadError; only the stdlib survives, which is the
  # validator's actual contract.
  def run_validator_process(*argv, chdir: REPO_ROOT)
    capture = lambda do
      Open3.capture3(RbConfig.ruby, "--disable-gems", VALIDATOR_PATH, *argv,
                     chdir: chdir)
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

require_relative "support/validation"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include SpecHelpers
  config.include ValidationHelpers
end
