//! The per-language replay configuration of the stage gems whose
//! plurimath-testsuite generations carry raw-tree rows (plurimath#540).
//!
//! Each stage gem writes its raw tree from the Ruby engine's parse result,
//! after a language-specific step this module ports:
//!
//!   latex      latexmath Latexmath::RawParser: the declared bindings'
//!              latex_tree capture, with CAPTURE_RENAMES (row_break ->
//!              "\\\\") (scripts/stage_cases.rb).
//!   asciimath  amath Amath.parse: the bare parse (no bindings), its :root
//!              unwrapped, then Amath::Renester rebuilding the nested tree
//!              of each flattened expression chain (lib/amath/parser.rb,
//!              lib/amath/renester.rb).
//!   unicode    umath Umath::RawParser: Umath::Preprocessor on the caller
//!              input (lib/umath/preprocessor.rb), the declared bindings'
//!              umath_tree capture, then scripts/unwrap.rb removing the
//!              wrapper captures listed in grammars/umath.wrappers.json.
//!
//! The ports work on the flattened parsanol-tree/v2 value: hashes, arrays,
//! strings, nil, and InputRef leaves standing for Parsanol::Slice.

import { flattenShape } from "./stage-canonical.js";

type Node = unknown;
type Hash = Record<string, Node>;
interface Ref {
  offset: number;
  length: number;
  value?: string;
  line?: number;
  column?: number;
}

/** What a replay needs to know about one language. */
export interface StageLanguage {
  name: string;
  /** The capture of the bound (or bare) tree that holds the raw tree. */
  capture: string;
  /** Apply the declared bindings artifact before taking the capture. */
  bindings: boolean;
  /** Decimal marker -> artifact entry (the gem's DECIMAL_ENTRIES). */
  decimalEntries: Record<string, string>;
  /** PARG capture -> legacy key, written as a String key. */
  renames: Record<string, string>;
  /** The wrapper table this language's transform reads, if any. */
  wrappers?: boolean;
  /** The gem's step from the captured tree to the written raw tree. */
  transform?: (tree: Node, context: TransformContext) => Node;
  /** The gem's preprocessing of the caller input into the grammar input,
   * for a language whose refusal rows record the offset in that text:
   * null when the input has no formula part. Languages without it parse a
   * refusal row's caller input. */
  preprocess?: (input: string) => string | null;
}

export interface TransformContext {
  /** The grammar input the InputRefs point into. */
  source: string;
  /** capture name -> wrapper kind (umath.wrappers.json "wrappers"). */
  wrappers?: Record<string, string>;
}

const DECIMAL_ENTRIES: Record<string, string> = { ".": "dot", ",": "comma", "٫": "arabic" };

export const LANGUAGES: Record<string, StageLanguage> = {
  latex: {
    name: "latex",
    capture: "latex_tree",
    bindings: true,
    decimalEntries: DECIMAL_ENTRIES,
    renames: { row_break: "\\\\" },
  },
  asciimath: {
    name: "asciimath",
    capture: "root",
    bindings: false,
    decimalEntries: DECIMAL_ENTRIES,
    renames: {},
    transform: (tree, context) => renest(tree, context.source),
  },
  unicode: {
    name: "unicode",
    capture: "umath_tree",
    bindings: true,
    decimalEntries: DECIMAL_ENTRIES,
    renames: {},
    wrappers: true,
    preprocess: (input) => umathPreprocess(input),
    transform: (tree, context) => {
      if (!context.wrappers) throw new Error("unicode replay needs the wrapper table");
      return unwrap(tree, context.wrappers, context.source);
    },
  },
};

// ---------------------------------------------------------------------------
// Value kinds, as Ruby sees them: Hash, Array, String, Parsanol::Slice.

function isRef(value: Node): value is Ref {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const node = value as Hash;
  if (typeof node.offset !== "number" || typeof node.length !== "number") return false;
  const allowed = new Set(["offset", "length", "value", "line", "column"]);
  return Object.keys(node).every((k) => allowed.has(k));
}

function isHash(value: Node): value is Hash {
  return value !== null && typeof value === "object" && !Array.isArray(value) && !isRef(value);
}

type Kind = "hash" | "array" | "string" | "slice" | "nil" | "other";

function kind(value: Node): Kind {
  if (value === null || value === undefined) return "nil";
  if (Array.isArray(value)) return "array";
  if (typeof value === "string") return "string";
  if (isRef(value)) return "slice";
  if (isHash(value)) return "hash";
  return "other";
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** The text of a slice: its value, else its bytes of `source`. */
function refText(ref: Ref, source: string): string {
  if (typeof ref.value === "string") return ref.value;
  const bytes = encoder.encode(source);
  return decoder.decode(bytes.subarray(ref.offset, ref.offset + ref.length));
}

/** Parsanol::Slice.new(offset, content): a slice at `offset` with `text`. */
function slice(offset: number, text: string): Ref {
  return { offset, length: encoder.encode(text).length, value: text };
}

function text(value: Node, source: string): string {
  return isRef(value) ? refText(value, source) : String(value);
}

// ---------------------------------------------------------------------------
// asciimath: Amath::Renester (lib/amath/renester.rb at the pinned commit).

const CHAIN = "amath_chain";
const FINAL = "amath_end";
const LEVELS: Record<string, string> = { amath_step: "expr", amath_lr: "left_right" };

/** `tree` with every chain node rebuilt into the nested tree. */
export function renest(tree: Node, source = ""): Node {
  const value = flattenShape(tree);
  const walk = (node: Node): Node => {
    if (Array.isArray(node)) return node.map(walk);
    if (!isHash(node)) return node;
    const rebuilt: Hash = {};
    for (const [k, v] of Object.entries(node)) rebuilt[k] = walk(v);
    if (CHAIN in node) {
      const nested = renestChain(rebuilt[CHAIN] as Node[], source);
      if (!isHash(nested)) throw new Error("amath: a chain without a level");
      return Object.values(nested)[0];
    }
    return rebuilt;
  };
  return walk(value);
}

function renestChain(items: Node[], source: string): Node {
  const last = items[items.length - 1];
  let tree: Node = isHash(last) && FINAL in last ? last[FINAL] : "";
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (!isHash(item)) continue;
    for (const [key, part] of Object.entries(item)) {
      const level = LEVELS[key];
      if (level) tree = { [level]: fold(part, tree, source) };
    }
  }
  return tree;
}

function fold(left: Node, right: Node, source: string): Node {
  if (left === null || left === undefined) return right === null || right === undefined ? "" : right;
  if (right === null || right === undefined) return left;
  return renesterMerge(left, right, source);
}

// Renester.merge: Parsanol's merge_fold without the duplicate-key warning.
function renesterMerge(left: Node, right: Node, source: string): Node {
  const l = kind(left);
  const r = kind(right);
  if (l === r) return plus(left, right, l, source);
  const lText = l === "string" || l === "slice";
  const rText = r === "string" || r === "slice";
  if (lText || rText) {
    if (!lText) return left;
    if (!rText) return right;
    return r === "slice" ? right : left;
  }
  if (r === "hash" && l === "array") return [...(left as Node[]), right];
  if (l === "hash" && r === "array") return [left, ...(right as Node[])];
  throw new Error(`amath: cannot merge ${l} with ${r}`);
}

// `left + right` (or Hash#merge) for two values of the same Ruby class.
function plus(left: Node, right: Node, k: Kind, source: string): Node {
  switch (k) {
    case "hash":
      return { ...(left as Hash), ...(right as Hash) };
    case "array":
      return [...(left as Node[]), ...(right as Node[])];
    case "string":
      return (left as string) + (right as string);
    case "slice":
      // Parsanol::Slice#+: the left slice's offset, the joined content.
      return slice((left as Ref).offset, text(left, source) + text(right, source));
    default:
      throw new Error(`cannot add two values of kind ${k}`);
  }
}

// ---------------------------------------------------------------------------
// unicode: umath scripts/unwrap.rb (UmathUnwrap) at the pinned commit, with
// Parsanol::Atoms::CanFlatten#merge_fold, #foldl and #flatten_repetition.

/** The legacy tree for `tree`, a raw tree of umath's normalized grammar. */
export function unwrap(tree: Node, table: Record<string, string>, source: string): Node {
  const call = (value: Node): Node => {
    if (Array.isArray(value)) return flattenRepetition(value.map(call), true, source);
    if (isHash(value)) return unwrapHash(value);
    return value;
  };
  const unwrapHash = (value: Hash): Node => {
    const keys = Object.keys(value);
    if (!keys.some((k) => k in table)) {
      const out: Hash = {};
      for (const k of keys) out[k] = call(value[k]);
      return out;
    }
    const parts: Node[] = [];
    let run: Hash | null = null;
    let onlyNil = true;
    for (const k of keys) {
      const wrapper = table[k];
      if (wrapper) {
        if (run) parts.push(run);
        run = null;
        onlyNil &&= wrapper === "nil";
        parts.push(part(wrapper, call(value[k])));
      } else {
        onlyNil = false;
        (run ??= {})[k] = call(value[k]);
      }
    }
    if (run) parts.push(run);
    if (onlyNil) return null;
    return foldl(parts, (l, r) => mergeFold(l, r, source));
  };
  return call(flattenShape(tree));
}

function part(wrapper: string, value: Node): Node {
  const empty = Array.isArray(value) && value.length === 0;
  switch (wrapper) {
    case "text":
      return value === null || value === undefined || empty ? "" : value;
    case "empty":
      return "";
    case "list":
      return empty ? "" : value;
    case "nil":
      return null;
    default:
      throw new Error(`unknown wrapper kind ${wrapper}`);
  }
}

// CanFlatten#foldl: "" for no element, else a left fold (nil elements
// included, as Ruby passes them to the block).
function foldl(list: Node[], merge: (l: Node, r: Node) => Node): Node {
  if (list.length === 0) return "";
  let result = list[0];
  for (let i = 1; i < list.length; i++) result = merge(result, list[i]);
  return result;
}

function mergeFold(left: Node, right: Node, source: string): Node {
  const l = kind(left);
  const r = kind(right);
  if (l === r) return plus(left, right, l, source);
  const lText = l === "string" || l === "slice";
  const rText = r === "string" || r === "slice";
  if (lText && rText) return r === "slice" ? right : left;
  if (rText) return left;
  if (lText) return right;
  if (r === "hash" && l === "array") return [...(left as Node[]), right];
  if (l === "hash" && r === "array") return [left, ...(right as Node[])];
  throw new Error(`Unhandled case when foldr'ing sequence (${l}, ${r}).`);
}

function flattenRepetition(list: Node[], named: boolean, source: string): Node {
  if (list.some(isHash)) return list.filter(isHash);
  if (list.some(Array.isArray)) return (list.filter(Array.isArray) as Node[][]).flat(1);
  if (named && list.length === 0) return [];
  // foldl(list.compact) { |s, e| s + e }: String#+ gives a String (a Slice
  // converts with to_str) and Slice#+ a Slice at its own offset, so the
  // first element decides the result's class.
  const present = list.filter((e) => e !== null && e !== undefined);
  if (present.length === 0) return "";
  const content = present.map((e) => text(e, source)).join("");
  const first = present[0];
  return isRef(first) ? slice(first.offset, content) : content;
}

// ---------------------------------------------------------------------------
// unicode: Umath::Preprocessor.call(input).text (lib/umath/preprocessor.rb at
// the pinned commit), step for step.

const PEN_OPEN = "\u270e(";
const PROTECTED_HASH = '"replacement"';
const COMMENT_OPEN = "&#x2af7;";
const COMMENT_CLOSE = "&#x2af8;";

/** The grammar input umath parses for `input`, or null without a formula. */
export function umathPreprocess(input: string): string | null {
  const protectedText = input.split("\n").map(protectPenGroup).join("\n");
  // Ruby String#split drops trailing empty fields.
  const parts = protectedText.split("#");
  while (parts.length > 0 && parts[parts.length - 1] === "") parts.pop();
  if (parts.length === 0) return null;
  let text = encodeEntities(parts[0].replaceAll(PROTECTED_HASH, "#"));
  text = text.replaceAll("&#x26;", "&");
  text = text.replaceAll("&#x22;", '"');
  text = removeComment(text);
  text = text.replaceAll("\\\\", "\\");
  text = text.replace(/\\u([\da-fA-F]{1,5})\w{0,5}/g, (_m, hex: string) => `&#x${hex};`);
  // Ruby String#strip; every character outside printable ASCII is encoded
  // by now, so only spaces can lead or trail.
  return text.replace(/^ +| +$/g, "");
}

function protectPenGroup(line: string): string {
  const start = line.indexOf(PEN_OPEN);
  if (start < 0) return line;
  const close = line.lastIndexOf(")");
  if (close < 0 || close < start + PEN_OPEN.length) return line;
  const hash = line.indexOf("#", start + PEN_OPEN.length);
  if (hash < 0 || hash >= close) return line;
  return line.slice(0, start) + line.slice(start, close + 1).replaceAll("#", PROTECTED_HASH) + line.slice(close + 1);
}

function removeComment(text: string): string {
  const start = text.indexOf(COMMENT_OPEN);
  if (start < 0) return text;
  const close = text.lastIndexOf(COMMENT_CLOSE);
  if (close < 0 || close < start + COMMENT_OPEN.length) return text;
  return text.slice(0, start) + text.slice(close + COMMENT_CLOSE.length);
}

function encodeEntities(text: string): string {
  const hex = (char: string) => `&#x${(char.codePointAt(0) as number).toString(16)};`;
  return text.replace(/[<>'"&]/g, hex).replace(/[^\u0020-\u007e]/gu, hex);
}
