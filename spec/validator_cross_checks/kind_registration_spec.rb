# frozen_string_literal: true

# Cross-field checks are dispatched on the schema that accepted the payload,
# through a table in scripts/validate.rb, and a kind absent from that table
# fails its payloads.
#
# This exists because the alternative already shipped a defect. Dispatch used
# to guess from the shape a payload carried, with an `else []` at the end, and
# the rejections kind matched none of the guesses: every rejection payload
# reported OK while its `group`, its per-case `input_format` and its ids went
# unchecked. `cases/2` would have hit the same trap from the other side — its
# shape happens to resemble `cases/1`, so it would have been checked by
# accident rather than by decision. A table that must be edited turns both
# into a loud failure.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "cross-field check registration" do
  it "fails a payload whose kind has no cross-field checks registered" do
    expect(validation_of(fixture("unregistered-kind"), "--no-integrity",
                         schema_dir: fixture("schemas/unregistered-kind")))
      .to fail_validation.with_violations(1)
      .reporting("/schema: is validated by widgets/1",
                 "registers no cross-field checks for")
  end

  it "names the kind by the schema's $id, not the payload's declaration" do
    # The two are not the same shape: a case payload declares
    # `plurimath-corpus/asciimath/2`, whose middle segment is the input
    # FORMAT, while a rejections or provenance payload carries a KIND there.
    # Keying on the declaration would make every input format a separate kind
    # to register, and would file `asciimath/2` under `asciimath`.
    schema = build_schema({ "$id" => "https://example.test/schema/cases/2" })
    expect(schema.kind).to eq("cases/2")
  end
end
