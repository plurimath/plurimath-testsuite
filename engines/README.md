# Engine replays

The stage generations under `stages/` are written by the Ruby stage gems
(latexmath, amath and umath). The programs here parse the same inputs on two
other parsanol engines and check that they produce the same raw trees. This
is part of plurimath/plurimath#540.

- `wasm/` uses the published `parsanol` npm package, which runs the parser
  as WebAssembly.
- `rust/` uses the published `parsanol` crate.

Both are pinned to exact versions, and each stage gem's grammar artifact is
pinned to the commit that the generation's provenance names for its
stage-gem producer.

## What is replayed

Only payloads with `boundary: raw-tree` are replayed. The generations are:

- latex: `stages/latex/generations/000003`, latexmath artifact `latex.json`
- asciimath: `stages/asciimath/generations/000003`, amath artifact
  `asciimath.json`
- unicode: `stages/unicode/generations/000004`, umath artifact `umath.json`
  and its wrapper table `grammars/umath.wrappers.json`

Each engine loads the artifact, parses every row, applies the gem's bindings
and its step from the parse result to the written tree where the gem has one,
and writes the result in the canonical tagged form that the gems'
`stage_cases.rb` uses.

## How rows are compared

A row that the generation records as parsed has its preprocessed text in
`expected.preprocessed.str`. The engine parses that text and the two trees
must be equal. Hash pairs are compared without regard to order, because pair
order is not part of the contract across engines. Slices are compared by
text, byte offset and character offset.

A row that the generation records as a refusal has no preprocessed text. For
latex the engine parses the caller's input, and the row is equal when the
engine also refuses with the same category (`parse_error`). The refusal
offset is reported but not compared, because latex records it in the
caller's input. Unicode records the offset in the preprocessed text, so for
its refusal rows the replay runs a port of `Umath::Preprocessor` on the
caller's input first. That port is checked against every row that does
record its preprocessed text, and a mismatch counts as a differing row.

Each run prints the number of equal and differing rows, then both trees of
every differing row. It exits with status 1 when any row differs. The
`engine-replays` workflow runs every engine and language pair on each push
to main and each pull request.

## Running locally

First check out the stage gem at its pinned commit, for example latexmath at
`27e300a433742765486e3bead2fac19ee8fd55a0`, next to this repository.

The wasm replay needs Node 22 or later:

    cd engines/wasm
    npm ci
    npm run replay -- ../../../latexmath/artifacts/latex.json \
      ../../stages/latex/generations/000003/payloads --language latex

The Rust replay reads JSON payloads, so convert the YAML ones first:

    mkdir -p /tmp/payloads
    for f in stages/latex/generations/000003/payloads/*.yaml; do
      ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file(ARGV[0]))' "$f" \
        > "/tmp/payloads/$(basename "$f" .yaml).json"
    done
    cd engines/rust
    cargo run --locked -- ../../../latexmath/artifacts/latex.json /tmp/payloads \
      --language latex

`--language` is `latex`, `asciimath` or `unicode`. The tests in each
directory (`npm test`, `cargo test`) cover the canonical form and the
preprocessing port, and replay a generation when `PARG_ARTIFACT_DIR`,
`STAGE_ARTIFACT` and `STAGE_PAYLOADS` (wasm) or `PARG_ARTIFACT` and
`STAGE_PAYLOADS` (Rust) are set, with `STAGE_LANGUAGE` naming the language.
