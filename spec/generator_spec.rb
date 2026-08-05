# frozen_string_literal: true

# Specs for scripts/generate-corpus.rb — deliberately only the helpers that
# do not need the plurimath gem loaded: lockfile parsing, deterministic YAML
# output, the option parser, and provenance assembly.
#
# BOUNDARY: everything that parses the oracle end-to-end (build_case,
# build_corpus, serialize_node, the checkout checks) is out of scope here on
# purpose. Those paths are proven by regenerating the corpus from the oracle
# and validating it — and a spec that shelled into the oracle's bundle on
# every CI run would be exactly the dependency this suite must not have.
# The gem itself is replaced by spec/support/plurimath-stub/plurimath.rb.

require_relative "spec_helper"

$LOAD_PATH.unshift(File.join(__dir__, "support", "plurimath-stub"))
GENERATOR_PATH = File.expand_path(ENV["TESTSUITE_GENERATOR"] ||
                                  File.join(REPO_ROOT, "scripts", "generate-corpus.rb"))
require GENERATOR_PATH

describe "parse_lockfile" do
  let(:lock) { CorpusGenerator.parse_lockfile(File.join(SpecHelpers::FIXTURES, "lockfiles", "sample.lock")) }

  it "reads every source section by kind" do
    assert_equal %w[path git gem], lock[:sources].map { |s| s["kind"] }
  end

  it "resolves every spec, including after a bare `specs:` line" do
    # The regression this pins: splitting on ": " instead of ":" missed the
    # bare `specs:` key, and zero dependencies were parsed.
    assert_equal %w[dep nokogiri parslet plurimath], lock[:specs].keys.sort
  end

  it "records name, version, platform and source per spec" do
    parslet = lock[:specs]["parslet"]
    assert_equal "2.0.0", parslet["version"]
    assert_equal "ruby", parslet["platform"]
    assert_equal "gem", parslet["source"]["kind"]
    assert_equal "https://rubygems.org/", parslet["source"]["remote"]
  end

  it "splits a platform suffix off the version" do
    nokogiri = lock[:specs]["nokogiri"]
    assert_equal "1.16.5", nokogiri["version"]
    assert_equal "x86_64-linux", nokogiri["platform"]
  end

  it "keeps a git source's revision and a path source's remote" do
    assert_equal "a" * 40, lock[:specs]["dep"]["source"]["revision"]
    assert_equal ".", lock[:specs]["plurimath"]["source"]["remote"]
  end

  it "does not record a sub-dependency line as a resolved version" do
    # `parslet (~> 2.0)` sits under plurimath at deeper indentation; only the
    # GEM section's `parslet (2.0.0)` may win.
    refute_equal "~> 2.0", lock[:specs]["parslet"]["version"]
  end

  it "collects platforms only from PLATFORMS, sorted" do
    # The regression this pins: every indented line of any unrecognised
    # section (DEPENDENCIES, CHECKSUMS, ...) was collected as a platform.
    assert_equal %w[ruby x86_64-linux], lock[:platforms]
  end

  it "reads the BUNDLED WITH version" do
    assert_equal "2.6.9", lock[:bundled_with]
  end
end

describe "lockfile_path" do
  it "returns the lockfile when it exists and demands one when it does not" do
    Dir.mktmpdir do |dir|
      error = assert_raises(CorpusGenerator::Error) { CorpusGenerator.lockfile_path(dir) }
      assert_includes error.message, "No Gemfile.lock in #{dir}"
      path = File.join(dir, "Gemfile.lock")
      File.write(path, "")
      assert_equal path, CorpusGenerator.lockfile_path(dir)
    end
  end
end

describe "direct_runtime_value" do
  let(:lock) { CorpusGenerator.parse_lockfile(File.join(SpecHelpers::FIXTURES, "lockfiles", "sample.lock")) }

  it "collapses a plainly-resolved gem to its bare version" do
    assert_equal "2.0.0", CorpusGenerator.direct_runtime_value(lock[:specs]["parslet"])
  end

  it "keeps the full resolution for a git source, revision included" do
    value = CorpusGenerator.direct_runtime_value(lock[:specs]["dep"])
    assert_equal "git", value["source_kind"]
    assert_equal "https://github.com/example/dep.git", value["source"]
    assert_equal "a" * 40, value["revision"]
  end

  it "keeps the full resolution for a platform-specific build, without a revision key" do
    value = CorpusGenerator.direct_runtime_value(lock[:specs]["nokogiri"])
    assert_equal "x86_64-linux", value["platform"]
    refute value.key?("revision")
  end
end

describe "dump_yaml" do
  it "emits no anchors or aliases even when one object is referenced twice" do
    shared = { "k" => "v" }
    yaml = CorpusGenerator.dump_yaml({ "a" => shared, "b" => shared })
    refute_includes yaml, "&"
    refute_includes yaml, "*"
    assert_equal({ "a" => { "k" => "v" }, "b" => { "k" => "v" } },
                 YAML.safe_load(yaml, aliases: false))
  end

  it "strips the trailing space Psych leaves after a nil value" do
    yaml = CorpusGenerator.dump_yaml({ "a" => nil, "b" => "x" })
    assert_includes yaml, "a:\n"
    assert yaml.lines.none? { |line| line.chomp.match?(/[ \t]\z/) },
           "a line still ends in whitespace:\n#{yaml.inspect}"
  end

  it "is deterministic: the same data dumps to the same bytes" do
    data = { "z" => [1, 2, { "y" => "s" }], "a" => nil }
    assert_equal CorpusGenerator.dump_yaml(data), CorpusGenerator.dump_yaml(data)
  end

  it "round-trips the payload unchanged" do
    data = { "text" => "multi\nline", "n" => 3, "list" => %w[a b] }
    assert_equal data, YAML.safe_load(CorpusGenerator.dump_yaml(data), aliases: false)
  end
end

describe "unshare" do
  it "rebuilds the structure so no two nodes are the same object" do
    shared = { "k" => "v" }
    rebuilt = CorpusGenerator.unshare([shared, shared])
    assert_equal [shared, shared], rebuilt
    refute rebuilt[0].equal?(rebuilt[1]), "the two entries are still one object"
  end
end

describe "parse_options" do
  it "defaults to no gem override, <repo>/corpus, and refusing dirty checkouts" do
    options = CorpusGenerator.parse_options([])
    assert_nil options[:gem]
    assert_equal File.join(CorpusGenerator::REPO_ROOT, "corpus"), options[:out]
    refute options[:allow_dirty]
  end

  it "expands --gem and --out to absolute paths" do
    options = CorpusGenerator.parse_options(["--gem", "/x/gem", "--out", "relative/out"])
    assert_equal "/x/gem", options[:gem]
    assert_equal File.expand_path("relative/out"), options[:out]
  end

  it "recognises --allow-dirty and both help spellings" do
    assert CorpusGenerator.parse_options(["--allow-dirty"])[:allow_dirty]
    assert CorpusGenerator.parse_options(["--help"])[:help]
    assert CorpusGenerator.parse_options(["-h"])[:help]
  end

  it "rejects an unknown option" do
    error = assert_raises(CorpusGenerator::Error) do
      CorpusGenerator.parse_options(["--bogus"])
    end
    assert_includes error.message, 'unknown option "--bogus"'
  end

  it "rejects a value-taking option left without a value" do
    error = assert_raises(CorpusGenerator::Error) do
      CorpusGenerator.parse_options(["--out"])
    end
    assert_includes error.message, 'missing value for option "--out"'
  end

  it "rejects an empty value, which would expand to the working directory" do
    error = assert_raises(CorpusGenerator::Error) do
      CorpusGenerator.parse_options(["--gem", ""])
    end
    assert_includes error.message, 'missing value for option "--gem"'
  end
end

describe "provenance assembly" do
  it "writes payload entries sorted by path with computed digests" do
    Dir.mktmpdir do |out|
      payloads = [
        [File.join(out, "asciimath", "zzz.yaml"), "content-z"],
        [File.join(out, "asciimath", "aaa.yaml"), "content-a"],
      ]
      path = CorpusGenerator.write_provenance(out, { "schema" => "s" }, payloads)

      assert_equal File.join(out, "provenance.yaml"), path
      text = File.read(path)
      assert text.start_with?("# Provenance shared by every payload"),
             "missing the provenance header"

      document = YAML.safe_load(text, aliases: false)
      assert_equal ["asciimath/aaa.yaml", "asciimath/zzz.yaml"],
                   document["payloads"].map { |entry| entry["path"] }
      assert_equal Digest::SHA256.hexdigest("content-a"),
                   document["payloads"][0]["sha256"]
      assert_equal "content-a".bytesize, document["payloads"][0]["bytes"]
    end
  end

  it "computes sha256 as the plain hex digest" do
    assert_equal "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                 CorpusGenerator.sha256("abc")
  end

  it "makes paths relative to a root, leaving outsiders untouched" do
    assert_equal "b/c", CorpusGenerator.relative("/a/b/c", "/a")
    assert_equal "/other/file", CorpusGenerator.relative("/other/file", "/a")
  end

  it "stamps every payload as generated, with the provenance location" do
    header = CorpusGenerator.payload_header("AsciiMath conformance cases: numbers.")
    assert_includes header, "Do not edit"
    assert_includes header, "corpus/provenance.yaml"
  end
end

describe "usage" do
  it "reads its own file header as the help text" do
    assert_includes CorpusGenerator.usage, "Usage, from the plurimath-testsuite repository root"
  end
end
