# frozen_string_literal: true

# Loads scripts/generate-corpus.rb for the specs under spec/generator/, with
# the plurimath gem replaced by spec/support/plurimath-stub/plurimath.rb.
#
# BOUNDARY: only the generator's gem-free helpers are specced — lockfile
# parsing, deterministic YAML output, the option parser, and provenance
# assembly. Everything that parses the oracle end-to-end (build_case,
# build_corpus, serialize_node, the checkout checks) is proven by
# regenerating the corpus from the oracle and validating it; a spec that
# shelled into the oracle's bundle on every CI run would be exactly the
# dependency this suite must not have.

GENERATOR_PATH = File.expand_path(ENV["TESTSUITE_GENERATOR"] ||
                                  File.join(REPO_ROOT, "scripts",
                                            "generate-corpus.rb"))

# The stub may be resolvable only while the generator file itself loads (its
# top-level `require "plurimath"`), never after: left on $LOAD_PATH, a later
# `require "plurimath"` anywhere else in the suite would silently resolve to
# the stub instead of failing. The $LOADED_FEATURES entry is dropped for the
# same reason — a repeat require must raise LoadError, not quietly return
# false against the stub.
stub_dir = File.join(__dir__, "plurimath-stub")
$LOAD_PATH.unshift(stub_dir)
begin
  require GENERATOR_PATH
ensure
  $LOAD_PATH.delete(stub_dir)
  $LOADED_FEATURES.delete_if { |feature| feature.start_with?(stub_dir) }
end
