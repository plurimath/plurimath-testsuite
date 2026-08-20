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
      a_string_matching(/says 999 cases/),
      a_string_matching(/says 888 groups/),
    )
  end
end
