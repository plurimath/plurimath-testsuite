# frozen_string_literal: true

# Builds generation N+1 of the openmath stage as the supersession of
# generation N: the previous generation's payloads stay byte for byte
# (the contract's carry-forward), and every row whose answer changed
# under the current gem gains an -r2 sibling in a <group>-r2 payload,
# carrying the same input and options and the answer the current gem
# returns. Rows the regenerator's selection no longer covers are
# recomputed live through the generator's own functions. Plainly new
# cases (the regenerator's wider selection) land in the -r2 payloads
# with their own ids, unrenamed.
#
# Run it inside a checkout of the openmath gem, in the gem's own bundle,
# after scripts/generate-openmath-stage.rb produced the candidate:
#
#   cd openmath && bundle exec ruby <testsuite>/scripts/supersede-openmath-stage.rb \
#     --candidate <candidate dir> --testsuite <testsuite checkout> \
#     --generator-commit <testsuite commit of supersede script>
require "yaml"
require "fileutils"
require "digest"
require "json"

prev_dir = ARGV.include?("--candidate") ? ARGV[ARGV.index("--candidate") + 1] : nil
testsuite = ARGV.include?("--testsuite") ? ARGV[ARGV.index("--testsuite") + 1] : nil
gen_commit = ARGV.include?("--generator-commit") ? ARGV[ARGV.index("--generator-commit") + 1] : nil
abort "missing --candidate/--testsuite/--generator-commit" unless prev_dir && testsuite && gen_commit

require_relative "generate-openmath-stage"
require "openmath"

root = File.expand_path(testsuite)
ledger = YAML.safe_load_file(File.join(root, "generations", "openmath.yaml"), aliases: false)
number = ledger["entries"].map { |e| e["generation"] }.max + 1
prev_number = number - 1
prev_payloads = File.join(root, "stages", "openmath", "generations", format("%06d", prev_number), "payloads")
out = File.join(root, "stages", "openmath", "generations", format("%06d", number))
abort "#{out} already exists" if File.exist?(out)

SUFFIX = /\.(model-roundtrip|validation|evaluation|cd-loading)\z/.freeze
gem_commit = OpenmathStage.git_head(Dir.pwd)
table_sha = OpenmathStage.sha(File.binread(File.join(Dir.pwd, "data", "binding-table-1.yml")))
# The testsuite commit that carries the previous generation, named by the
# copied payloads' source.
prev_commit = Open3.capture2("git", "-C", root, "log", "--format=%H", "-1",
                             "--", "stages/openmath/generations/#{format('%06d', prev_number)}")
  .first.strip

payloads = []
FileUtils.mkdir_p(File.join(out, "payloads"))

def write_payload(out, payloads, name, group, boundary, description, cases)
  doc = OpenmathStage.payload(group, boundary, description, cases)
  text = "# Written by plurimath-testsuite scripts/supersede-openmath-stage.rb. " \
         "Do not edit.\n" + YAML.dump(doc)
  File.binwrite(File.join(out, "payloads", "#{name}.yaml"), text)
  payloads << { "path" => "payloads/#{name}.yaml", "bytes" => text.bytesize,
                "sha256" => OpenmathStage.sha(text),
                "producer" => "openmath",
                "source" => { "relation" => "generated", "file" => nil },
                "rows" => doc["cases"].map { |c| c["id"] } }
end

changed_groups = []
Dir[File.join(prev_payloads, "*.yaml")].sort.each do |path|
  name = File.basename(path)
  group = name.delete_suffix(".yaml")
  candidate = File.join(prev_dir, "payloads", name)
  if File.exist?(candidate) && File.binread(candidate) == File.binread(path)
    FileUtils.cp(path, File.join(out, "payloads", name))
    payloads << { "path" => "payloads/#{name}", "bytes" => File.size(path),
                  "sha256" => Digest::SHA256.file(path).hexdigest,
                  "producer" => "openmath",
                  "source" => { "relation" => "copy",
                                "file" => { "repository" => OpenmathStage::SUITE_URL,
                                            "commit" => prev_commit,
                                            "path" => "stages/openmath/generations/#{format('%06d', prev_number)}/payloads/#{name}",
                                            "sha256" => Digest::SHA256.file(path).hexdigest } },
                  "rows" => YAML.safe_load_file(path, aliases: false)["cases"].map { |c| c["id"] } }
    next
  end

  # The group changed: previous bytes stay verbatim; the current answers
  # land in a <group>-r2 payload.
  changed_groups << group
  FileUtils.cp(path, File.join(out, "payloads", name))
  payloads << { "path" => "payloads/#{name}", "bytes" => File.size(path),
                "sha256" => Digest::SHA256.file(path).hexdigest,
                "producer" => "openmath",
                "source" => { "relation" => "copy",
                              "file" => { "repository" => OpenmathStage::SUITE_URL,
                                          "commit" => prev_commit,
                                          "path" => "stages/openmath/generations/#{format('%06d', prev_number)}/payloads/#{name}",
                                          "sha256" => Digest::SHA256.file(path).hexdigest } },
                "rows" => YAML.safe_load_file(path, aliases: false)["cases"].map { |c| c["id"] } }
  previous = YAML.safe_load_file(path, aliases: false)
  current = YAML.safe_load_file(candidate, aliases: false)
  prev_by_id = previous["cases"].to_h { |c| [c["id"], c] }
  cur_by_id = current["cases"].to_h { |c| [c["id"], c] }

  rows = []
  current["cases"].each do |case_row|
    old = prev_by_id[case_row["id"]]
    if old.nil?
      rows << case_row # a plainly new case
    elsif old != case_row
      superseded = case_row.dup
      superseded["id"] = case_row["id"].sub(SUFFIX, "-r2.\\1")
      rows << superseded
    end
  end
  # Previous cases the regenerator's selection no longer covers: recompute
  # the current answer live (evaluation rows only — the other boundaries
  # regenerate over complete sets).
  (prev_by_id.keys - cur_by_id.keys).each do |id|
    old = prev_by_id[id]
    vars = JSON.parse(old.dig("options", "variables") || "{}")
    expected = OpenmathStage.evaluate_expected(old.dig("input", "str"), vars, nil)
    rows << { "id" => id.sub(SUFFIX, "-r2.\\1"), "input" => old["input"],
              "options" => OpenmathStage.evaluation_options(vars, table_sha),
              "expected" => expected }
  end
  abort "#{group}: no supersession rows for a changed payload" if rows.empty?

  rows.sort_by! { |r| r["id"].b }
  write_payload(out, payloads, "#{group}-r2", "#{group}-r2",
                current["boundary"],
                "Generation #{number} supersessions of #{group}: the answers " \
                "the current openmath gem returns for the rows its expansion " \
                "changed. -r2 ids supersede their originals (kept above); " \
                "unrenamed ids are cases the wider selection adds.",
                rows)
end

# --- provenance -------------------------------------------------------------

candidate_provenance = YAML.safe_load_file(File.join(prev_dir, "provenance.yaml"), aliases: false)
doc = {
  "schema" => "plurimath-stage/provenance/1",
  "language" => "openmath",
  "generation" => number,
  "notes" => "Generation #{number}: supersession of generation #{prev_number} under the " \
             "expanded openmath gem (binding table v4, OMFOREIGN foreign-markup capture). " \
             "Generation #{prev_number}'s payloads stay byte for byte; the groups whose " \
             "answers changed (#{changed_groups.join(', ')}) gain -r2 siblings computed by " \
             "scripts/supersede-openmath-stage.rb from openmath #{gem_commit[0, 7]}, with the " \
             "regenerator's candidate produced by scripts/generate-openmath-stage.rb. The " \
             "inputs are generation #{prev_number}'s, recorded in its provenance.",
  "producers" => {
    "openmath" => {
      "kind" => "stage-gem",
      "repository" => OpenmathStage::GEM_URL,
      "commit" => gem_commit,
      "version" => Openmath::VERSION,
      "generator" => { "repository" => OpenmathStage::SUITE_URL, "commit" => gen_commit,
                       "path" => "scripts/supersede-openmath-stage.rb",
                       "sha256" => OpenmathStage.sha(File.binread(File.join(testsuite, "scripts", "supersede-openmath-stage.rb"))) },
      "inputs" => candidate_provenance.dig("producers", "openmath", "inputs"),
      "environment" => candidate_provenance.dig("producers", "openmath", "environment"),
      "semantic_boundary" => "model-roundtrip",
      "configuration" => { "entry_point" => "Openmath.parse", "versions" => %w[2 3],
                           "serializer" => "to_xml", "supersedes" => prev_number },
    },
  },
  "payloads" => payloads.sort_by { |p| p["path"].b },
}
File.binwrite(File.join(out, "provenance.yaml"),
              "# Generation #{number} of the openmath stage corpus. Immutable: never edit this\n" \
              "# directory; add a new generation instead. See docs/stage-corpus-contract.adoc.\n" +
              YAML.dump(doc))

# The ledger entry with the testsuite's snapshot digest formula.
names = Dir.children(out).flat_map do |entry|
  path = File.join(out, entry)
  File.directory?(path) ? Dir.glob(File.join(entry, "**", "*"), base: out) : [entry]
end.sort_by(&:b)
lines = names.map do |name|
  "#{Digest::SHA256.file(File.join(out, name)).hexdigest}  #{name}\n"
end
digest = "sha256:#{Digest::SHA256.hexdigest(lines.join.encode('UTF-8'))}"

ledger["entries"] << {
  "generation" => number,
  "path" => "stages/openmath/generations/#{format('%06d', number)}",
  "snapshot_digest" => digest,
  "payloads" => payloads.size,
  "rows" => payloads.sum { |p| p["rows"].size },
  "producer_kinds" => ["stage-gem"],
  "change" => "extend",
  "rationale" => "Generation #{number}: supersession of generation #{prev_number} under the " \
                 "expanded openmath gem (binding table v4, OMFOREIGN capture) — the changed " \
                 "groups (#{changed_groups.join(', ')}) gain -r2 rows at openmath " \
                 "#{gem_commit[0, 7]}; every other payload copies byte for byte.",
}
File.write(File.join(root, "generations", "openmath.yaml"), YAML.dump(ledger))
puts "generation #{format('%06d', number)}: #{payloads.size} payloads, " \
     "#{payloads.sum { |p| p['rows'].size }} rows, #{digest}"
