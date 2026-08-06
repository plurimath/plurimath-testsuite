# frozen_string_literal: true

# In-process validator runs, and the matchers the corpus specs are written
# in:
#
#   expect(validation_of(fixture("..."), "--no-integrity"))
#     .to fail_validation.with_violations(1).reporting("...")

module ValidationHelpers
  Result = Struct.new(:status, :output)

  # In-process run of the CLI. A usage or schema error raises
  # Testsuite::Failure here, exactly as documented — the process-level
  # mapping of that raise to exit code 2 is covered by spec/validator_cli/.
  def validation_of(corpus_root, *flags, schema_dir: SpecHelpers::SCHEMA_DIR)
    argv = [corpus_root, "--schema", schema_dir, *flags]
    captured = StringIO.new
    original = $stdout
    $stdout = captured
    status = Testsuite::CLI.run(argv)
    Result.new(status, captured.string)
  ensure
    $stdout = original
  end
end

RSpec::Matchers.define :pass_validation do
  match { |result| result.status.zero? }

  failure_message do |result|
    "expected a pass, got exit #{result.status}:\n#{result.output}"
  end
end

# The run must fail (exit 1) and the report must name the reason.
#
# `with_violations` pins the TOTAL count of reported violations — pass 1 for
# a one-defect fixture. Without the pin, a fixture that rots and starts
# failing for a second, unintended reason still passes its spec.
RSpec::Matchers.define :fail_validation do
  chain :reporting do |*messages|
    @messages = messages
  end

  chain :with_violations do |count|
    @violations = count
  end

  match do |result|
    @problems = []
    unless result.status == 1
      @problems << "expected a validation failure (exit 1), " \
                   "got exit #{result.status}"
    end
    (@messages || []).each do |message|
      unless result.output.include?(message)
        @problems << "the report never says #{message.inspect}"
      end
    end
    unless @violations.nil?
      counted = count_violations(result.output)
      unless counted == @violations
        @problems << "expected exactly #{@violations} violation(s), " \
                     "got #{counted}"
      end
    end
    @problems.empty?
  end

  failure_message do |result|
    "#{@problems.join("\n")}\nthe report:\n#{result.output}"
  end

  # A violation is an indented report line opening with a JSON pointer.
  # `/\S*: /` was tried and missed pointers containing spaces (`/bad key: ...`).
  def count_violations(output)
    output.lines.count { |line| line.match?(%r{\A\s+/.*?: }) }
  end
end
