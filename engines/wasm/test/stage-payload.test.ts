import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readStagePayload } from "../src/stage-payload.js";

function withPayload(content: string, check: (path: string) => void): void {
  const directory = mkdtempSync(join(tmpdir(), "stage-yaml-"));
  try {
    // Spaces and shell punctuation must remain an ordinary path argument.
    const path = join(directory, "payload 'quoted' $.yaml");
    writeFileSync(path, content);
    check(path);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

describe("sealed stage payloads use Psych's scalar values", () => {
  it("keeps the historical numeric output strings, booleans and integers", () => {
    withPayload(
      "output: 0e0\nother: 1e21\ngrouped: 1.123_456_789\ncount: 17\nflag: true\n",
      (path) => assert.deepEqual(readStagePayload(path), {
        output: "0e0", other: "1e21", grouped: "1.123_456_789", count: 17, flag: true,
      }),
    );
  });

  it("preserves raw-tree slices and offsets", () => {
    withPayload(
      'boundary: raw-tree\ncases:\n- id: alpha\n  tree:\n    slice: "α"\n    byte_offset: 2\n',
      (path) => assert.deepEqual(readStagePayload(path), {
        boundary: "raw-tree", cases: [{ id: "alpha", tree: { slice: "α", byte_offset: 2 } }],
      }),
    );
  });

  it("rejects aliases and unsafe tags", () => {
    for (const content of ["a: &a [1]\nb: *a\n", "a: !ruby/object:Object {}\n"]) {
      withPayload(content, (path) => assert.throws(() => readStagePayload(path)));
    }
  });
});
