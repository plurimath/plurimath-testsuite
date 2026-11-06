//! Replays a plurimath-testsuite stage generation's raw-tree rows on the
//! wasm engine and compares them with the Ruby-produced expectations
//! (plurimath#540, requirement 3: per-target replay).
//!
//!   node dist/src/replay-stage.js <artifact.json> <payloads> [options]
//!
//! <payloads> is a payload file or a directory of *.yaml payloads
//! (schema plurimath-stage/<language>/cases/1); only the raw-tree ones
//! (boundary raw-tree) are replayed.
//!
//! Options:
//!   --language NAME   latex (default), asciimath or unicode: the stage
//!                     gem's capture, decimal entries and the step from the
//!                     parse result to the written raw tree
//!                     (src/stage-languages.ts)
//!   --bindings PATH   declared bindings artifact (default: the artifact's
//!                     sibling <name>.bindings.ts.json when present, for a
//!                     language whose gem applies its bindings)
//!   --wrappers PATH   unicode: the wrapper table (default: the artifact's
//!                     ../grammars/<name>.wrappers.json)
//!   --capture NAME    override the capture that holds the tree
//!   --json PATH       also write the full report as JSON
//!
//! Each row parses `expected.preprocessed.str` (preprocessing is Ruby
//! code; the generation records its output), not the caller input. A row
//! the generation records as a refusal carries no preprocessed text, so
//! its caller input is parsed and the outcome compared by category; the
//! refusal byte offset is in the caller's input on the Ruby side and is
//! reported, not compared. Exit status 1 when any row differs.
//! (latex records that offset in the caller's input. unicode records it in
//! the preprocessed text, which a refusal row does not record: the replay
//! runs the ported Umath::Preprocessor on the caller input there, and
//! checks that port against every row that records its preprocessed text.)

import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse as parseYaml } from "yaml";
import { PargRuntime } from "parsanol";
import { LANGUAGES, type StageLanguage } from "./stage-languages.js";
import {
  type Canonical,
  canonicalEqual,
  dumpCanonical,
  refusal,
  sortCanonical,
} from "./stage-canonical.js";

export interface ReplayOptions {
  artifact: string;
  payloads: string;
  /** A key of LANGUAGES (default latex). */
  language?: string;
  bindings?: string | null;
  wrappers?: string | null;
  capture?: string;
  decimalEntries?: Record<string, string>;
  renames?: Record<string, string>;
}

export interface ReplayRow {
  payload: string;
  id: string;
  input: string;
  parsed: string;
  status: "equal" | "differ";
  reason?: string;
  expected: unknown;
  actual: unknown;
  /** For a refusal row: the wasm offset in the parsed text and the
   * generation's offset in the caller input. */
  refusalOffsets?: { wasm: number | null; expected: number | null };
}

export interface ReplayReport {
  language: string;
  artifact: string;
  compilerVersion: string | null;
  bindings: string | null;
  rows: ReplayRow[];
  equal: number;
  differ: number;
}

interface PayloadCase {
  id: string;
  input: { str?: string };
  options?: { decimal?: string };
  expected: {
    preprocessed?: { str?: string };
    tree?: unknown;
    refusal?: { category: string; byte_offset: number | null };
  };
}

/** The payload files: one file, or a directory's *.yaml in byte order.
 * (asciimath's raw-tree payload is not named raw-*; the boundary field
 * decides which are replayed.) */
export function payloadFiles(path: string): string[] {
  if (statSync(path).isFile()) return [path];
  return readdirSync(path)
    .filter((f) => f.endsWith(".yaml"))
    .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map((f) => join(path, f));
}

function defaultBindings(artifact: string): string | null {
  const candidate = join(dirname(artifact), `${basename(artifact, ".json")}.bindings.ts.json`);
  return existsSync(candidate) ? candidate : null;
}

function defaultWrappers(artifact: string): string {
  return join(dirname(artifact), "..", "grammars", `${basename(artifact, ".json")}.wrappers.json`);
}

/** The language configuration named `name`. */
export function stageLanguage(name: string): StageLanguage {
  const language = LANGUAGES[name];
  if (!language) throw new Error(`unknown language ${name} (known: ${Object.keys(LANGUAGES).join(", ")})`);
  return language;
}

// The wasm parse failure names its byte offset: "Parse failed at offset N".
function failureOffset(error: unknown): number | null {
  const message = error instanceof Error ? error.message : String(error);
  const match = /offset (\d+)/.exec(message);
  return match ? Number(match[1]) : null;
}

export function replayStage(options: ReplayOptions): ReplayReport {
  const language = stageLanguage(options.language ?? "latex");
  const capture = options.capture ?? language.capture;
  const entries = options.decimalEntries ?? language.decimalEntries;
  const renames = options.renames ?? language.renames;
  const bindingsPath =
    options.bindings !== undefined ? options.bindings : language.bindings ? defaultBindings(options.artifact) : null;
  const bindingsJson = bindingsPath ? readFileSync(bindingsPath, "utf8") : null;
  let wrappers: Record<string, string> | undefined;
  if (language.wrappers) {
    const path = options.wrappers ?? defaultWrappers(options.artifact);
    wrappers = (JSON.parse(readFileSync(path, "utf8")) as { wrappers: Record<string, string> }).wrappers;
  }

  const runtimes = new Map<string, PargRuntime>();
  const artifactJson = readFileSync(options.artifact, "utf8");
  const runtimeFor = (entry: string): PargRuntime => {
    let rt = runtimes.get(entry);
    if (!rt) {
      rt = new PargRuntime(artifactJson, entry);
      runtimes.set(entry, rt);
    }
    return rt;
  };
  const first = runtimeFor(entries["."] ?? Object.values(entries)[0]);

  const rows: ReplayRow[] = [];
  for (const file of payloadFiles(options.payloads)) {
    const doc = parseYaml(readFileSync(file, "utf8")) as { boundary?: string; cases?: PayloadCase[] };
    if (doc.boundary !== "raw-tree") continue;
    for (const row of doc.cases ?? []) {
      const decimal = row.options?.decimal ?? ".";
      const entry = entries[decimal];
      if (!entry) throw new Error(`${row.id}: no entry for decimal marker ${JSON.stringify(decimal)}`);
      const rt = runtimeFor(entry);
      const input = row.input.str ?? "";
      const isRefusal = row.expected.refusal !== undefined;
      // The ported preprocessing, when the language has one: checked
      // against every recorded preprocessed text, and the text a refusal
      // row's grammar run saw.
      const preprocessed = language.preprocess ? language.preprocess(input) : undefined;
      if (preprocessed === null) throw new Error(`${row.id}: the input has no formula part`);
      const text = isRefusal ? (preprocessed ?? input) : row.expected.preprocessed?.str;
      if (text === undefined) throw new Error(`${row.id}: expected neither a preprocessed text nor a refusal`);

      let actual: Canonical;
      let wasmOffset: number | null = null;
      try {
        let tree: unknown = rt.parseShape(text);
        if (bindingsJson) tree = rt.applyBindingsArtifact(bindingsJson, tree);
        const bound = tree as Record<string, unknown>;
        if (bound === null || typeof bound !== "object" || !(capture in bound)) {
          throw new Error(`${row.id}: the tree has no ${capture} capture`);
        }
        const raw = language.transform
          ? language.transform(bound[capture], { source: text, wrappers })
          : bound[capture];
        actual = dumpCanonical(raw, { source: text, renames });
      } catch (error) {
        if (error instanceof Error && error.message.startsWith(`${row.id}:`)) throw error;
        wasmOffset = failureOffset(error);
        actual = refusal(wasmOffset);
      }

      const out: ReplayRow = {
        payload: basename(file),
        id: row.id,
        input,
        parsed: text,
        status: "equal",
        expected: isRefusal ? { refusal: row.expected.refusal } : row.expected.tree,
        actual: sortCanonical(actual),
      };
      if (preprocessed !== undefined && !isRefusal && preprocessed !== text) {
        out.status = "differ";
        out.reason = `the ported preprocessing gives ${JSON.stringify(preprocessed)}`;
      } else if (isRefusal) {
        const expectedOffset = row.expected.refusal?.byte_offset ?? null;
        out.refusalOffsets = { wasm: wasmOffset, expected: expectedOffset };
        if (!("refusal" in actual)) {
          out.status = "differ";
          out.reason = "the generation refuses, wasm parsed";
        } else if (row.expected.refusal?.category !== "parse_error") {
          out.status = "differ";
          out.reason = `refusal category ${row.expected.refusal?.category}`;
        }
      } else if ("refusal" in actual) {
        out.status = "differ";
        out.reason = "the generation parsed, wasm refused";
      } else if (!canonicalEqual(actual, row.expected.tree)) {
        out.status = "differ";
        out.reason = "trees differ";
      }
      rows.push(out);
    }
  }
  const differ = rows.filter((r) => r.status === "differ").length;
  return {
    language: language.name,
    artifact: options.artifact,
    compilerVersion: first.compilerVersion,
    bindings: bindingsPath,
    rows,
    equal: rows.length - differ,
    differ,
  };
}

/** The report as text: one line per differing row with both trees. */
export function formatReport(report: ReplayReport): string {
  const lines = [
    `language ${report.language}`,
    `artifact ${report.artifact} (compiler ${report.compilerVersion ?? "unknown"})`,
    `bindings ${report.bindings ?? "none (raw shape)"}`,
    `${report.rows.length} rows: ${report.equal} equal, ${report.differ} differ`,
  ];
  for (const row of report.rows.filter((r) => r.status === "differ")) {
    lines.push(
      `DIFFER ${row.payload} ${row.id}: ${row.reason}`,
      `  input:    ${JSON.stringify(row.input)}`,
      `  parsed:   ${JSON.stringify(row.parsed)}`,
      `  expected: ${JSON.stringify(sortCanonical(row.expected))}`,
      `  actual:   ${JSON.stringify(row.actual)}`,
    );
  }
  const offsets = report.rows.filter(
    (r) => r.refusalOffsets && r.refusalOffsets.wasm !== r.refusalOffsets.expected,
  );
  if (offsets.length > 0) {
    lines.push(`refusal offsets not compared, ${offsets.length} differ:`);
    for (const r of offsets) {
      lines.push(`  ${r.id}: wasm ${r.refusalOffsets?.wasm} in ${JSON.stringify(r.parsed)}, generation ${r.refusalOffsets?.expected}`);
    }
  }
  return `${lines.join("\n")}\n`;
}

function main(argv: string[]): number {
  const positional: string[] = [];
  const opts: Partial<ReplayOptions> & { json?: string } = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--bindings") opts.bindings = argv[++i];
    else if (arg === "--language") opts.language = argv[++i];
    else if (arg === "--wrappers") opts.wrappers = argv[++i];
    else if (arg === "--capture") opts.capture = argv[++i];
    else if (arg === "--json") opts.json = argv[++i];
    else positional.push(arg);
  }
  if (positional.length !== 2) {
    process.stderr.write("usage: replay-stage <artifact.json> <payload file or dir> [--language NAME] [--bindings PATH] [--wrappers PATH] [--capture NAME] [--json PATH]\n");
    return 2;
  }
  const report = replayStage({ ...opts, artifact: positional[0], payloads: positional[1] });
  process.stdout.write(formatReport(report));
  if (opts.json) writeFileSync(opts.json, `${JSON.stringify(report, null, 2)}\n`);
  return report.differ === 0 ? 0 : 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
