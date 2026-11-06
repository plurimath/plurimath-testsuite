//! Canonical tagged form for staged-testsuite replay (plurimath#540).
//!
//! A port of `Canonical.dump` from plurimath/latexmath
//! scripts/stage_cases.rb, which writes the raw-tree rows of the
//! plurimath-testsuite stage payloads. The Ruby side dumps a
//! Parslet-style tree (Hashes, Arrays, Parsanol::Slice leaves); here the
//! input is the parsanol-tree/v2 JSON the wasm engine returns, so the v2
//! node kinds are flattened first (docs/PARSANOL-SHAPE-v2.md in
//! parsanol-rs) and then dumped to the same tagged form:
//!
//!   nil          -> { nil: true }
//!   boolean      -> { bool: b }
//!   integer      -> { int: "<decimal>" }
//!   hash key     -> { sym: name }, or { str: name } for a renamed key
//!   string       -> { str: s }
//!   array        -> { array: [...] }
//!   hash         -> { hash: [[key, value], ...] }
//!   InputRef     -> { slice, byte_offset, char_offset }
//!
//! Hash pair order is not part of the contract across engines (serde
//! emits sorted keys, Ruby keeps insertion order), so `canonicalEqual`
//! and `sortCanonical` treat a hash as an unordered set of pairs.

/** A value in canonical tagged form. */
export type Canonical =
  | { nil: true }
  | { bool: boolean }
  | { int: string }
  | { sym: string }
  | { str: string }
  | { slice: string; byte_offset: number; char_offset?: number }
  | { array: Canonical[] }
  | { hash: [Canonical, Canonical][] }
  | { refusal: { category: string; byte_offset: number | null } };

export interface DumpOptions {
  /** The grammar input the slices point into; gives `char_offset` and
   * the text of an InputRef that carries no `value`. */
  source?: string;
  /** Capture names to write as a String key instead of a Symbol, with
   * the key to write (latexmath's CAPTURE_RENAMES: row_break -> "\\\\"). */
  renames?: Record<string, string>;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: false });

/** An InputRef leaf: `{offset, length}` plus optional value/line/column. */
function isInputRef(value: Record<string, unknown>): boolean {
  if (typeof value.offset !== "number" || typeof value.length !== "number") return false;
  const allowed = new Set(["offset", "length", "value", "line", "column"]);
  return Object.keys(value).every((k) => allowed.has(k));
}

/** A TaggedArray node: `{tag, items[]}`. */
function isTaggedArray(value: Record<string, unknown>): boolean {
  const keys = Object.keys(value);
  return keys.length === 2 && typeof value.tag === "string" && Array.isArray(value.items);
}

/**
 * Flatten parsanol-tree/v2 TaggedArray nodes the way the Parslet-style
 * binders do: `sequence` concatenates its items (hashes merge, a single
 * item is itself), `repetition` becomes an array, `maybe` (absent) becomes
 * nil. Hashes, InputRefs, arrays and nil pass through, flattened inside.
 * The wasm JSON is normally already flat; this keeps the port total over
 * the v2 contract.
 */
export function flattenShape(value: unknown): unknown {
  if (value === null || value === undefined) return null;
  if (Array.isArray(value)) return value.map(flattenShape);
  if (typeof value !== "object") return value;
  const node = value as Record<string, unknown>;
  if (isInputRef(node)) return node;
  if (isTaggedArray(node)) {
    const items = (node.items as unknown[]).map(flattenShape);
    const tag = (node.tag as string).replace(/^:/, "");
    if (tag === "repetition") return items;
    if (tag === "maybe") return items.length === 0 ? null : items[0];
    if (tag === "sequence") return foldSequence(items);
    throw new Error(`parsanol-tree/v2: unknown TaggedArray tag ${JSON.stringify(node.tag)}`);
  }
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(node)) out[k] = flattenShape(v);
  return out;
}

// Parslet's sequence fold: hashes merge, nils drop out, a lone item is
// itself, otherwise the items stay a list.
function foldSequence(items: unknown[]): unknown {
  const present = items.filter((i) => i !== null);
  if (present.length === 0) return null;
  if (present.length === 1) return present[0];
  const hashes = present.filter(
    (i) => i !== null && typeof i === "object" && !Array.isArray(i) && !isInputRef(i as Record<string, unknown>),
  );
  if (hashes.length === present.length) return Object.assign({}, ...hashes);
  if (hashes.length > 0) {
    // Captures win over bare spans in a sequence: the spans are dropped.
    const onlyHashesAndRefs = present.every(
      (i) => hashes.includes(i) || isInputRef(i as Record<string, unknown>),
    );
    if (onlyHashesAndRefs) return Object.assign({}, ...hashes);
  }
  return present;
}

/** The text of an InputRef: its `value`, else the bytes of `source`. */
function refText(ref: Record<string, unknown>, sourceBytes: Uint8Array | null): string {
  if (typeof ref.value === "string") return ref.value;
  if (!sourceBytes) throw new Error("InputRef without value and no source to slice");
  const start = ref.offset as number;
  return decoder.decode(sourceBytes.subarray(start, start + (ref.length as number)));
}

/** Characters (code points) in the first `byteOffset` bytes of `bytes`. */
function charOffset(bytes: Uint8Array, byteOffset: number): number {
  return [...decoder.decode(bytes.subarray(0, byteOffset))].length;
}

/**
 * `value` (a flattened or raw parsanol-tree/v2 node) in canonical tagged
 * form — `Canonical.dump(value, source:)` of stage_cases.rb.
 */
export function dumpCanonical(value: unknown, options: DumpOptions = {}): Canonical {
  const bytes = options.source === undefined ? null : encoder.encode(options.source);
  const renames = options.renames ?? {};
  const dump = (v: unknown): Canonical => {
    if (v === null || v === undefined) return { nil: true };
    if (typeof v === "boolean") return { bool: v };
    if (typeof v === "number") {
      if (!Number.isInteger(v)) throw new Error(`no canonical form for non-integer ${v}`);
      return { int: String(v) };
    }
    if (typeof v === "string") return { str: v };
    if (Array.isArray(v)) return { array: v.map(dump) };
    if (typeof v === "object") {
      const node = v as Record<string, unknown>;
      if (isInputRef(node)) {
        const slice: Canonical = { slice: refText(node, bytes), byte_offset: node.offset as number };
        if (bytes) (slice as { char_offset?: number }).char_offset = charOffset(bytes, node.offset as number);
        return slice;
      }
      if (isTaggedArray(node)) return dump(flattenShape(node));
      return {
        hash: Object.entries(node).map(([k, item]): [Canonical, Canonical] => [
          k in renames ? { str: renames[k] } : { sym: k },
          dump(item),
        ]),
      };
    }
    throw new Error(`no canonical form for ${typeof v}`);
  };
  return dump(flattenShape(value));
}

/** A refusal in payload form (category parse_error). */
export function refusal(byteOffset: number | null): Canonical {
  return { refusal: { category: "parse_error", byte_offset: byteOffset } };
}

// Stable string for ordering hash pairs.
function sortKey(value: unknown): string {
  return JSON.stringify(value);
}

/** `value` with every hash's pairs in a fixed order (by canonical key),
 * object keys sorted — the form two runtimes compare byte for byte. */
export function sortCanonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortCanonical);
  if (value === null || typeof value !== "object") return value;
  const node = value as Record<string, unknown>;
  if (Array.isArray(node.hash) && Object.keys(node).length === 1) {
    const pairs = (node.hash as [unknown, unknown][]).map(
      ([k, v]) => [sortCanonical(k), sortCanonical(v)] as [unknown, unknown],
    );
    pairs.sort((a, b) => {
      const ka = sortKey(a[0]);
      const kb = sortKey(b[0]);
      return ka < kb ? -1 : ka > kb ? 1 : 0;
    });
    return { hash: pairs };
  }
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(node).sort()) out[key] = sortCanonical(node[key]);
  return out;
}

/** Equality of two canonical values, ignoring hash pair order. */
export function canonicalEqual(a: unknown, b: unknown): boolean {
  return JSON.stringify(sortCanonical(a)) === JSON.stringify(sortCanonical(b));
}
