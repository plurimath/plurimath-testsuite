# frozen_string_literal: true

# The integrity layer: provenance and the files on disk must be the same set,
# entry for entry, digest for digest — and --no-integrity must skip exactly
# these checks, nothing more.

require_relative "spec_helper"

describe "provenance presence" do
  it "rejects a corpus with payloads but no provenance" do
    assert_rejects fixture("integrity-missing-provenance"),
                   violations: 1, message: ["provenance.yaml",
                             "is missing; without it every payload here is unattributed"]
  end

  it "rejects a corpus where two files declare the provenance schema" do
    assert_rejects fixture("integrity-two-provenance"),
                   violations: 1, message: "the corpus has one provenance document, but 2 declare it"
  end

  it "rejects a provenance document that is not at the corpus root" do
    assert_rejects fixture("integrity-provenance-not-at-root"),
                   violations: 1, message: "must be the corpus root's"
  end
end

describe "digests and coverage" do
  it "rejects a payload whose sha256 does not match" do
    assert_rejects fixture("integrity-sha-mismatch"),
                   violations: 1, message: ["/payloads/0/sha256", "but that file hashes to"]
  end

  it "rejects a payload whose byte count does not match" do
    assert_rejects fixture("integrity-bytes-mismatch"),
                   violations: 1, message: ["/payloads/0/bytes: records 999999 bytes",
                             "but that file is"]
  end

  it "rejects a payload on disk that provenance never mentions" do
    assert_rejects fixture("integrity-unrecorded-payload"),
                   violations: 1, message: ["extra.yaml", "is not recorded in"]
  end

  it "rejects a recorded payload that is not on disk" do
    assert_rejects fixture("integrity-ghost-payload"),
                   violations: 1, message: ["records asciimath/ghost.yaml, which is not a payload in"]
  end

  it "rejects a payload recorded twice" do
    assert_rejects fixture("integrity-duplicate-entry"),
                   violations: 1, message: "records asciimath/numbers.yaml a second time"
  end
end

describe "integrity and the provenance's own validity" do
  it "does not run integrity against a provenance that failed its schema" do
    out = assert_rejects fixture("integrity-skips-broken-provenance"),
                         violations: 1, message: "/committable: expected false, got true"
    refute_includes out, "is not recorded",
                    "integrity ran against a provenance there is no reason to trust"
  end
end

describe "--no-integrity" do
  it "skips the digest comparison" do
    assert_accepts fixture("integrity-sha-mismatch"), "--no-integrity"
  end

  it "skips the provenance-presence requirement" do
    assert_accepts fixture("integrity-missing-provenance"), "--no-integrity"
  end

  it "still validates every file against its schema" do
    assert_rejects fixture("cases-missing-required"), "--no-integrity",
                   violations: 1, message: "is missing the required property `description`"
  end
end

describe "healthy corpora" do
  it "passes the minimal healthy corpus, integrity included" do
    out = assert_accepts fixture("healthy-minimal")
    assert_includes out, "2 files: 1 payload (1 case), 1 provenance — all valid"
  end

  it "still passes when a tmpdir copy is re-validated in place" do
    with_fixture_copy("healthy-minimal") do |dir|
      assert_accepts dir
    end
  end

  it "fails the same copy the moment one payload byte changes" do
    with_fixture_copy("healthy-minimal") do |dir|
      payload = File.join(dir, "asciimath", "numbers.yaml")
      File.binwrite(payload, File.binread(payload).sub('input: "2"', 'input: "3"'))
      assert_rejects dir, message: ["/payloads/0/sha256", "but that file hashes to"]
    end
  end
end
