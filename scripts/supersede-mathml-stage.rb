# frozen_string_literal: true

# Builds the next generation of the mathml stage as the supersession of
# the latest one: the previous generation's payloads stay byte for byte
# (the contract's carry-forward), and every model-roundtrip row whose
# answer changed under the current mml gem gains an -r2 sibling in its
# group's <group>-r2 payload, carrying the same input and the answer the
# current gem returns.
#
# Run it inside a checkout of the mml gem, in the gem's own bundle:
#
#   cd mml && bundle exec ruby <testsuite>/scripts/supersede-mathml-stage.rb \
#     --testsuite <testsuite checkout>
require "digest"
require "fileutils"
require "open3"
require "optparse"
require "yaml"

testsuite = nil
OptionParser.new do |o|
  o.on("--testsuite PATH") { |v| testsuite = v }
end.parse(ARGV)
abort "missing --testsuite" unless testsuite

root = File.expand_path(testsuite)
ledger = YAML.safe_load_file(File.join(root, "generations", "mathml.yaml"),
                             aliases: false)
prev_number = ledger["entries"].map { |e| e["generation"] }.max
number = prev_number + 1
prev_dir = File.join(root, "stages", "mathml", "generations",
                     format("%06d", prev_number))
out = File.join(root, "stages", "mathml", "generations",
                format("%06d", number))
abort "#{out} already exists" if File.exist?(out)

require "mml"
require_relative File.expand_path("scripts/replay_corpus", Dir.pwd)

gem_commit = Open3.capture2("git", "rev-parse", "HEAD").first.strip
script_commit = Open3.capture2("git", "-C", root, "rev-parse", "HEAD").first.strip
script_sha = Digest::SHA256.hexdigest(File.read(__FILE__))
prev_provenance = YAML.safe_load_file(File.join(prev_dir, "provenance.yaml"),
                                      aliases: false)
prev_inputs = prev_provenance["producers"]["mml"]["inputs"]
prev_commit = Open3.capture2("git", "-C", root, "log", "--format=%H", "-1",
                             "--", prev_dir).first.strip

# Pass one: recompute every model-roundtrip row of the pinned generation
# and collect the -r2 siblings of the rows whose answer changed.
new_payloads = {}
changed = []
prev_provenance["payloads"].each do |entry|
  name = entry["path"]
  bytes = File.binread(File.join(prev_dir, name))
  doc = YAML.safe_load(bytes, aliases: false)
  new_payloads[name] = bytes

  next unless doc["boundary"] == "model-roundtrip"

  supers = doc["cases"].filter_map do |row|
    actual = MmlReplayCorpus.outcome(row["input"]["str"])
    next if actual == row["expected"]

    { "id" => row["id"].sub(/\.model-roundtrip\z/, "-r2.model-roundtrip"),
      "input" => row["input"], "options" => row["options"],
      "expected" => actual }
  end
  next if supers.empty?

  changed << [name, doc, supers]
end

abort "nothing changed; no supersession needed" if changed.empty?

# Pass two: write the generation.
out_dir = File.join(out, "payloads")
FileUtils.mkdir_p(out_dir)
payload_entries = []
changed.each do |name, doc, supers|
  group = doc["group"]
  payload = {
    "schema" => doc["schema"],
    "group" => "#{group}-r2",
    "description" => "Supersessions of #{group}: the answers the current " \
                     "mml gem returns for the rows its dependency " \
                     "resolution changed. -r2 ids supersede the originals, " \
                     "which stay for history.",
    "boundary" => doc["boundary"],
    "cases" => supers,
  }
  text = "# Written by plurimath-testsuite " \
         "scripts/supersede-mathml-stage.rb. Do not edit.\n" +
         YAML.dump(payload)
  r2_name = name.sub(/\.yaml\z/, "-r2.yaml")
  File.binwrite(File.join(out_dir, File.basename(r2_name)), text)
  payload_entries << {
    "path" => "payloads/#{File.basename(r2_name)}",
    "bytes" => text.bytesize,
    "sha256" => Digest::SHA256.hexdigest(text),
    "producer" => "mml",
    "source" => { "relation" => "generated", "file" => nil },
    "rows" => supers.map { |c| c["id"] },
  }
end
new_payloads.each do |name, bytes|
  File.binwrite(File.join(out_dir, File.basename(name)), bytes)
  payload_entries << {
    "path" => "payloads/#{File.basename(name)}",
    "bytes" => bytes.bytesize,
    "sha256" => Digest::SHA256.hexdigest(bytes),
    "producer" => "mml",
    "source" => {
      "relation" => "copy",
      "file" => {
        "repository" => "https://github.com/plurimath/plurimath-testsuite",
        "commit" => prev_commit,
        "path" => "#{prev_dir}/#{name}",
        "sha256" => Digest::SHA256.hexdigest(bytes),
      },
    },
    "rows" => prev_provenance["payloads"]
              .find { |e| e["path"] == name }["rows"],
  }
end

changed_list = changed.map do |name, _, supers|
  "#{name} (#{supers.map { |c| c["id"] }.join(', ')})"
end.join("; ")
provenance = {
  "schema" => "plurimath-stage/provenance/1",
  "language" => "mathml",
  "generation" => number,
  "notes" => "Supersession of generation #{prev_number}: the " \
             "model-roundtrip answers the current mml gem returns under " \
             "the dependencies it resolves today (lutaml-model " \
             "#{Gem.loaded_specs['lutaml-model'].version}, moxml " \
             "#{Gem.loaded_specs['moxml'].version}) differ for " \
             "#{changed.sum { |_, _, s| s.size }} row(s): #{changed_list}. " \
             "The originals stay byte for byte. Recomputed by " \
             "scripts/supersede-mathml-stage.rb with mml #{Mml::VERSION} " \
             "at #{gem_commit[0, 7]}.",
  "producers" => {
    "mml" => {
      "kind" => "stage-gem",
      "repository" => "https://github.com/plurimath/mml",
      "commit" => gem_commit,
      "version" => Mml::VERSION,
      "generator" => {
        "repository" => "https://github.com/plurimath/plurimath-testsuite",
        "commit" => script_commit,
        "path" => "scripts/supersede-mathml-stage.rb",
        "sha256" => script_sha,
      },
      "inputs" => prev_inputs,
    },
  },
  "payloads" => payload_entries.sort_by { |e| e["path"].b },
}
text = "# Generation #{number} of the mathml stage corpus. Immutable: " \
       "never edit this directory; add a new generation instead. See " \
       "docs/stage-corpus-contract.adoc.\n---\n" + YAML.dump(provenance)
File.binwrite(File.join(out, "provenance.yaml"), text)

snapshot = Dir.glob(File.join(out, "**", "*"))
              .reject { |p| File.directory?(p) }
              .sort_by { |p| p.delete_prefix("#{out}/").b }
              .map do |p|
  "#{Digest::SHA256.hexdigest(File.binread(p))}  " \
    "#{p.delete_prefix("#{out}/")}\n"
end.join
digest = "sha256:#{Digest::SHA256.hexdigest(snapshot.encode('UTF-8'))}"

ledger["entries"] << {
  "generation" => number,
  "path" => "stages/mathml/generations/#{format('%06d', number)}",
  "snapshot_digest" => digest,
  "payloads" => payload_entries.size,
  "rows" => payload_entries.sum { |e| e["rows"].size },
  "producer_kinds" => ["stage-gem"],
  "change" => "extend",
  "rationale" => "Generation #{number}: supersession of generation " \
                 "#{prev_number} — #{changed.sum { |_, _, s| s.size }} " \
                 "model-roundtrip row(s) changed under mml #{Mml::VERSION} " \
                 "(#{gem_commit[0, 7]}) with lutaml-model " \
                 "#{Gem.loaded_specs['lutaml-model'].version} / moxml " \
                 "#{Gem.loaded_specs['moxml'].version}; the changed rows " \
                 "gain -r2 siblings, every payload copies byte for byte.",
}
File.write(File.join(root, "generations", "mathml.yaml"), YAML.dump(ledger))

puts "generation #{number}: #{payload_entries.size} payloads, " \
     "#{changed.sum { |_, _, s| s.size }} superseded row(s), #{digest}"
