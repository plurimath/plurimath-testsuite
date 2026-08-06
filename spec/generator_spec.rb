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

GENERATOR_PATH = File.expand_path(ENV["TESTSUITE_GENERATOR"] ||
                                  File.join(REPO_ROOT, "scripts", "generate-corpus.rb"))

# The stub may be resolvable only while the generator file itself loads (its
# top-level `require "plurimath"`), never after: left on $LOAD_PATH, a later
# `require "plurimath"` anywhere else in the suite would silently resolve to
# the stub instead of failing. The $LOADED_FEATURES entry is dropped for the
# same reason — a repeat require must raise LoadError, not quietly return
# false against the stub.
stub_dir = File.join(__dir__, "support", "plurimath-stub")
$LOAD_PATH.unshift(stub_dir)
begin
  require GENERATOR_PATH
ensure
  $LOAD_PATH.delete(stub_dir)
  $LOADED_FEATURES.delete_if { |feature| feature.start_with?(stub_dir) }
end

RSpec.describe "parse_lockfile" do
  let(:lock) { CorpusGenerator.parse_lockfile(File.join(SpecHelpers::FIXTURES, "lockfiles", "sample.lock")) }

  it "reads every source section by kind" do
    expect(lock[:sources].map { |s| s["kind"] }).to eq(%w[path git gem])
  end

  it "resolves every spec, including after a bare `specs:` line" do
    # The regression this pins: splitting on ": " instead of ":" missed the
    # bare `specs:` key, and zero dependencies were parsed.
    expect(lock[:specs].keys.sort).to eq(%w[dep nokogiri parslet plurimath])
  end

  it "records name, version, platform and source per spec" do
    parslet = lock[:specs]["parslet"]
    expect(parslet["version"]).to eq("2.0.0")
    expect(parslet["platform"]).to eq("ruby")
    expect(parslet["source"]["kind"]).to eq("gem")
    expect(parslet["source"]["remote"]).to eq("https://rubygems.org/")
  end

  it "splits a platform suffix off the version" do
    nokogiri = lock[:specs]["nokogiri"]
    expect(nokogiri["version"]).to eq("1.16.5")
    expect(nokogiri["platform"]).to eq("x86_64-linux")
  end

  it "keeps a git source's revision and a path source's remote" do
    expect(lock[:specs]["dep"]["source"]["revision"]).to eq("a" * 40)
    expect(lock[:specs]["plurimath"]["source"]["remote"]).to eq(".")
  end

  it "does not record a sub-dependency line as a resolved version" do
    # `parslet (~> 2.0)` sits under plurimath at deeper indentation; only the
    # GEM section's `parslet (2.0.0)` may win.
    expect(lock[:specs]["parslet"]["version"]).not_to eq("~> 2.0")
  end

  it "collects platforms only from PLATFORMS, sorted" do
    # The regression this pins: every indented line of any unrecognised
    # section (DEPENDENCIES, CHECKSUMS, ...) was collected as a platform.
    expect(lock[:platforms]).to eq(%w[ruby x86_64-linux])
  end

  it "reads the BUNDLED WITH version" do
    expect(lock[:bundled_with]).to eq("2.6.9")
  end
end

RSpec.describe "lockfile_path" do
  it "returns the lockfile when it exists and demands one when it does not" do
    Dir.mktmpdir do |dir|
      expect { CorpusGenerator.lockfile_path(dir) }
        .to raise_error(CorpusGenerator::Error) { |error|
          expect(error.message).to include("No Gemfile.lock in #{dir}")
        }
      path = File.join(dir, "Gemfile.lock")
      File.write(path, "")
      expect(CorpusGenerator.lockfile_path(dir)).to eq(path)
    end
  end
end

RSpec.describe "direct_runtime_value" do
  let(:lock) { CorpusGenerator.parse_lockfile(File.join(SpecHelpers::FIXTURES, "lockfiles", "sample.lock")) }

  it "collapses a plainly-resolved gem to its bare version" do
    expect(CorpusGenerator.direct_runtime_value(lock[:specs]["parslet"])).to eq("2.0.0")
  end

  it "keeps the full resolution for a git source, revision included" do
    value = CorpusGenerator.direct_runtime_value(lock[:specs]["dep"])
    expect(value["source_kind"]).to eq("git")
    expect(value["source"]).to eq("https://github.com/example/dep.git")
    expect(value["revision"]).to eq("a" * 40)
  end

  it "keeps the full resolution for a platform-specific build, without a revision key" do
    value = CorpusGenerator.direct_runtime_value(lock[:specs]["nokogiri"])
    expect(value["platform"]).to eq("x86_64-linux")
    expect(value).not_to have_key("revision")
  end
end

RSpec.describe "dump_yaml" do
  it "emits no anchors or aliases even when one object is referenced twice" do
    shared = { "k" => "v" }
    yaml = CorpusGenerator.dump_yaml({ "a" => shared, "b" => shared })
    expect(yaml).not_to include("&")
    expect(yaml).not_to include("*")
    expect(YAML.safe_load(yaml, aliases: false))
      .to eq({ "a" => { "k" => "v" }, "b" => { "k" => "v" } })
  end

  it "strips the trailing space Psych leaves after a nil value" do
    yaml = CorpusGenerator.dump_yaml({ "a" => nil, "b" => "x" })
    expect(yaml).to include("a:\n")
    trailing = yaml.lines.select { |line| line.chomp.match?(/[ \t]\z/) }
    expect(trailing).to be_empty,
                        "a line still ends in whitespace:\n#{yaml.inspect}"
  end

  it "is deterministic: the same data dumps to the same bytes" do
    data = { "z" => [1, 2, { "y" => "s" }], "a" => nil }
    expect(CorpusGenerator.dump_yaml(data)).to eq(CorpusGenerator.dump_yaml(data))
  end

  it "round-trips the payload unchanged" do
    data = { "text" => "multi\nline", "n" => 3, "list" => %w[a b] }
    expect(YAML.safe_load(CorpusGenerator.dump_yaml(data), aliases: false)).to eq(data)
  end
end

RSpec.describe "unshare" do
  it "rebuilds the structure so no two nodes are the same object" do
    shared = { "k" => "v" }
    rebuilt = CorpusGenerator.unshare([shared, shared])
    expect(rebuilt).to eq([shared, shared])
    expect(rebuilt[0]).not_to equal(rebuilt[1]), "the two entries are still one object"
  end
end

RSpec.describe "parse_options" do
  it "defaults to no gem override, <repo>/corpus, and refusing dirty checkouts" do
    options = CorpusGenerator.parse_options([])
    expect(options[:gem]).to be_nil
    expect(options[:out]).to eq(File.join(CorpusGenerator::REPO_ROOT, "corpus"))
    expect(options[:allow_dirty]).to be_falsey
  end

  it "expands --gem and --out to absolute paths" do
    options = CorpusGenerator.parse_options(["--gem", "/x/gem", "--out", "relative/out"])
    expect(options[:gem]).to eq("/x/gem")
    expect(options[:out]).to eq(File.expand_path("relative/out"))
  end

  it "recognises --allow-dirty and both help spellings" do
    expect(CorpusGenerator.parse_options(["--allow-dirty"])[:allow_dirty]).to be_truthy
    expect(CorpusGenerator.parse_options(["--help"])[:help]).to be_truthy
    expect(CorpusGenerator.parse_options(["-h"])[:help]).to be_truthy
  end

  it "rejects an unknown option" do
    expect { CorpusGenerator.parse_options(["--bogus"]) }
      .to raise_error(CorpusGenerator::Error) { |error|
        expect(error.message).to include('unknown option "--bogus"')
      }
  end

  it "rejects a value-taking option left without a value" do
    expect { CorpusGenerator.parse_options(["--out"]) }
      .to raise_error(CorpusGenerator::Error) { |error|
        expect(error.message).to include('missing value for option "--out"')
      }
  end

  it "rejects an empty value, which would expand to the working directory" do
    expect { CorpusGenerator.parse_options(["--gem", ""]) }
      .to raise_error(CorpusGenerator::Error) { |error|
        expect(error.message).to include('missing value for option "--gem"')
      }
  end
end

RSpec.describe "provenance assembly" do
  it "writes payload entries sorted by path with computed digests" do
    Dir.mktmpdir do |out|
      payloads = [
        [File.join(out, "asciimath", "zzz.yaml"), "content-z"],
        [File.join(out, "asciimath", "aaa.yaml"), "content-a"],
      ]
      path = CorpusGenerator.write_provenance(out, { "schema" => "s" }, payloads)

      expect(path).to eq(File.join(out, "provenance.yaml"))
      text = File.read(path)
      expect(text).to start_with("# Provenance shared by every payload"),
                      "missing the provenance header"

      document = YAML.safe_load(text, aliases: false)
      expect(document["payloads"].map { |entry| entry["path"] })
        .to eq(["asciimath/aaa.yaml", "asciimath/zzz.yaml"])
      expect(document["payloads"][0]["sha256"])
        .to eq(Digest::SHA256.hexdigest("content-a"))
      expect(document["payloads"][0]["bytes"]).to eq("content-a".bytesize)
    end
  end

  it "computes sha256 as the plain hex digest" do
    expect(CorpusGenerator.sha256("abc"))
      .to eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  end

  it "makes paths relative to a root, leaving outsiders untouched" do
    expect(CorpusGenerator.relative("/a/b/c", "/a")).to eq("b/c")
    expect(CorpusGenerator.relative("/other/file", "/a")).to eq("/other/file")
  end

  it "stamps every payload as generated, with the provenance location" do
    header = CorpusGenerator.payload_header("AsciiMath conformance cases: numbers.")
    expect(header).to include("Do not edit")
    expect(header).to include("corpus/provenance.yaml")
  end

  it "carries the kind it was given, not a fixed label" do
    # A review mutation gutted `payload_header` to discard its argument and
    # emit a fixed string — and the suite stayed green, because only the fixed
    # text above was asserted. The kind is the part that varies per file, so it
    # is the part a mutation corrupts.
    numbers = CorpusGenerator.payload_header("AsciiMath conformance cases: numbers.")
    frac = CorpusGenerator.payload_header("AsciiMath conformance cases: frac.")
    expect(numbers).to include("# AsciiMath conformance cases: numbers.\n")
    expect(frac).to include("# AsciiMath conformance cases: frac.\n")
    expect(numbers).not_to eq(frac)
  end
end

RSpec.describe "usage" do
  it "reads its own file header as the help text" do
    expect(CorpusGenerator.usage)
      .to include("Usage, from the plurimath-testsuite repository root")
  end
end
