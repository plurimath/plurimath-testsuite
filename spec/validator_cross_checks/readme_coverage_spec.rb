# frozen_string_literal: true

# The README's coverage table restates numbers the corpus already knows, so the
# validator checks it against the corpus rather than trusting the prose.
#
# These specs exist because that check had a hole and nothing noticed. The
# "N cases, N groups" claim was guarded by an explicit `nil?` test, but the
# "checked for all N" claims were only ever validated by iterating whatever the
# scan found — so removing every such row left nothing to iterate and the check
# reported success. A drift guard that passes when the thing it guards is
# deleted is worse than no guard, because the README then promises protection
# that is not there.
#
# The expected number of claims is DERIVED from the corpus (one per declared
# target), not fixed at "at least one", so dropping a single row fails too.

require_relative "../spec_helper"

RSpec.describe Testsuite::Runner, "README coverage claims" do
  # `check_readme` reads the repository's own README, so these drive the
  # underlying method with substituted text instead of writing to the file.
  let(:runner) do
    described_class.new(
      corpus_root: File.expand_path("../../corpus", __dir__),
      schema_dir: File.expand_path("../../schema", __dir__),
      integrity: false,
      allow_empty: false,
    ).tap do |instance|
      # The discovery half of `run`, without the validation and reporting: the
      # counts these checks compare against come from `@corpus_paths`, which is
      # otherwise only populated part-way through a full run.
      paths = instance.send(:corpus_files).select { |path| instance.send(:allowed_layout?, path) }
      instance.instance_variable_set(:@corpus_paths, paths)
      instance.instance_variable_set(
        :@provenance_paths,
        paths.select { |path| path.end_with?("/#{described_class::PROVENANCE_PATH}") },
      )
    end
  end

  let(:readme) { File.read(File.expand_path("../../README.adoc", __dir__)) }

  def errors_for(text)
    runner.send(:readme_count_errors, text)
  end

  it "accepts the README as it stands" do
    expect(errors_for(readme)).to be_empty
  end

  it "derives one expected claim per target the corpus declares" do
    targets = runner.send(:positive_targets)
    expect(targets).to eq(%w[asciimath latex mathml unicodemath])
    expect(readme.scan(/checked for all \d+/).length).to eq(targets.length)
  end

  it "rejects a README that drops every coverage claim" do
    stripped = readme.gsub(/checked for all \d+/, "documented elsewhere")
    expect(errors_for(stripped))
      .to include(a_string_matching(/makes 0 "checked for all N" claims/))
  end

  it "rejects a README that drops a single target's claim" do
    one_less = readme.sub(/checked for all \d+/, "documented elsewhere")
    expect(errors_for(one_less))
      .to include(a_string_matching(/makes 3 "checked for all N" claims/))
  end

  it "rejects a README whose claimed count disagrees with the corpus" do
    wrong = readme.gsub(/checked for all \d+/, "checked for all 4242")
    expect(errors_for(wrong))
      .to include(a_string_matching(/"checked for all 4242", corpus has \d+/))
  end

  it "rejects a README whose cases-and-groups line disagrees" do
    wrong = readme.sub(/(\| AsciiMath\s+\| ✅ )\d+ cases, \d+ groups/, '\1999 cases, 888 groups')
    expect(errors_for(wrong)).to include(
      a_string_matching(/says 999 cases for AsciiMath/),
      a_string_matching(/says 888 groups for AsciiMath/),
    )
  end

  # One row per input format the corpus holds cases for, not one row for the
  # corpus as a whole. A single claim would say nothing about which format the
  # cases are in, and the row is read for exactly that — and while the check
  # keyed on AsciiMath alone, a second format's row could say anything.
  it "checks one coverage row per input format the corpus holds cases for" do
    expect(runner.send(:positive_groups).keys.sort).to eq(%w[asciimath latex])

    unstated = readme.sub(/^\| LaTeX\s+\|[^|]*\|/) do |row|
      row.sub(/\d+ cases, \d+ groups/, "some cases")
    end
    expect(errors_for(unstated))
      .to include(a_string_matching(/no "N cases, N groups" claim for LaTeX/))
    # And specifically NOT the missing-row wording: the row is right there.
    expect(errors_for(unstated)).not_to include(a_string_matching(/has no LaTeX row/))
  end

  it "distinguishes a missing notation row from a row without numbers" do
    # Deleting the row entirely is a different failure from leaving it in place
    # without a count, and each sends the reader somewhere different.
    without_row = readme.sub(/^\| LaTeX\s+\|.*$\n/, "")
    expect(errors_for(without_row))
      .to include(a_string_matching(/the coverage table has no LaTeX row, but the corpus has \d+/))
    expect(errors_for(without_row))
      .not_to include(a_string_matching(/no "N cases, N groups" claim for LaTeX/))
  end

  # A format the corpus holds cases for but the label table does not name has
  # no row anyone is comparing, which is the drift this check exists to catch.
  it "rejects a corpus format with no README label registered" do
    counts = runner.send(:positive_groups)
      .merge("klingon" => { "numbers" => 1 })
    runner.instance_variable_set(:@positive_groups, counts)
    expect(errors_for(readme))
      .to include(a_string_matching(/no README label is registered.+`klingon`/))
  end

  # Group names repeat across input formats, so an inventory entry names a
  # payload by its path stem. A bare group name identifies two payloads at once.
  it "rejects a group inventory entry whose count disagrees" do
    wrong = readme.sub(%r{`latex/numbers` \d+}, "`latex/numbers` 42")
    expect(runner.send(:readme_group_errors, wrong))
      .to include(a_string_matching(%r{`latex/numbers` 42, corpus has \d+}))
  end
end
