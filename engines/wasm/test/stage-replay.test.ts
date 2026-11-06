import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { join } from "node:path";
import {
  canonicalEqual,
  dumpCanonical,
  flattenShape,
  sortCanonical,
} from "../src/stage-canonical.js";
import { formatReport, replayStage } from "../src/replay-stage.js";
import { umathPreprocess } from "../src/stage-languages.js";

const ref = (offset: number, value: string) => ({ offset, length: Buffer.byteLength(value), line: 1, column: offset + 1, value });

describe("stage canonical form (latexmath stage_cases.rb Canonical.dump)", () => {
  it("dumps hashes, symbols, slices with byte and char offsets", () => {
    const source = "x^2";
    const tree = { power: { supscript: { number: ref(2, "2") }, symbols: ref(0, "x") } };
    assert.deepEqual(dumpCanonical(tree, { source }), {
      hash: [[
        { sym: "power" },
        {
          hash: [
            [{ sym: "supscript" }, { hash: [[{ sym: "number" }, { slice: "2", byte_offset: 2, char_offset: 2 }]] }],
            [{ sym: "symbols" }, { slice: "x", byte_offset: 0, char_offset: 0 }],
          ],
        },
      ]],
    });
  });

  it("counts char offsets in code points over UTF-8 bytes", () => {
    const source = "αβx";
    const canonical = dumpCanonical({ symbols: { offset: 4, length: 1 } }, { source });
    assert.deepEqual(canonical, { hash: [[{ sym: "symbols" }, { slice: "x", byte_offset: 4, char_offset: 2 }]] });
  });

  it("writes renamed captures as string keys, arrays and nil", () => {
    const canonical = dumpCanonical(
      { row_break: ref(0, "\\\\"), expression: [null] },
      { source: "\\\\", renames: { row_break: "\\\\" } },
    );
    assert.deepEqual(canonical, {
      hash: [
        [{ str: "\\\\" }, { slice: "\\\\", byte_offset: 0, char_offset: 0 }],
        [{ sym: "expression" }, { array: [{ nil: true }] }],
      ],
    });
  });

  it("flattens v2 TaggedArray nodes", () => {
    assert.deepEqual(flattenShape({ tag: "repetition", items: [{ a: null }, { a: null }] }), [{ a: null }, { a: null }]);
    assert.equal(flattenShape({ tag: "maybe", items: [] }), null);
    assert.deepEqual(flattenShape({ tag: "sequence", items: [{ a: null }, { b: null }] }), { a: null, b: null });
  });

  it("compares hashes ignoring pair order", () => {
    const a = { hash: [[{ sym: "a" }, { str: "1" }], [{ sym: "b" }, { str: "2" }]] };
    const b = { hash: [[{ sym: "b" }, { str: "2" }], [{ sym: "a" }, { str: "1" }]] };
    assert.ok(canonicalEqual(a, b));
    assert.deepEqual(sortCanonical(a), sortCanonical(b));
    assert.ok(!canonicalEqual(a, { hash: [[{ sym: "a" }, { str: "1" }]] }));
  });
});

describe("umath preprocessing port (Umath::Preprocessor)", () => {
  it("encodes everything outside printable ASCII as hex entities", () => {
    assert.equal(umathPreprocess("\u2061"), "&#x2061;");
    assert.equal(umathPreprocess("a\u2061"), "a&#x2061;");
    assert.equal(umathPreprocess("\u03b1\u2061"), "&#x3b1;&#x2061;");
    assert.equal(umathPreprocess("\u{1d44e}"), "&#x1d44e;");
  });

  it("keeps & and \", splits the label off and strips spaces", () => {
    assert.equal(umathPreprocess(" a&b\"c\" "), 'a&b"c"');
    assert.equal(umathPreprocess("x#label"), "x");
    assert.equal(umathPreprocess("#"), null);
    assert.equal(umathPreprocess("\u270e(a#b)"), "&#x270e;(a#b)");
  });

  it("removes comments, halves double backslashes and expands \\u escapes", () => {
    assert.equal(umathPreprocess("a\u2af7note\u2af8b"), "ab");
    assert.equal(umathPreprocess("\\\\x"), "\\x");
    assert.equal(umathPreprocess("\\u03b1"), "&#x03b1;");
  });
});

describe("stage replay on the wasm engine", () => {
  it("replays a raw-tree generation with no differing rows when provided", () => {
    // artifact-gated: PARG_ARTIFACT_DIR holds the artifact (STAGE_ARTIFACT,
    // default latex.json), STAGE_PAYLOADS is the generation's payloads
    // directory and STAGE_LANGUAGE the stage language (default latex).
    const dir = process.env.PARG_ARTIFACT_DIR;
    const payloads = process.env.STAGE_PAYLOADS;
    if (!dir || !payloads) return;
    const artifact = join(dir, process.env.STAGE_ARTIFACT ?? "latex.json");
    if (!existsSync(artifact)) return;
    const report = replayStage({ artifact, payloads, language: process.env.STAGE_LANGUAGE ?? "latex" });
    assert.ok(report.rows.length > 0, "no raw-tree rows found");
    assert.equal(report.differ, 0, formatReport(report));
  });
});
