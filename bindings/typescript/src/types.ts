// Public enums and the error type, shared across the binding.
//
// ENUMS. Every enum here is a frozen-shape object literal (`as const`) paired
// with a type of the same name — `Format.Markdown` is a value, `Format` a type
// — rather than a TypeScript `enum`, so Node's strip-only TypeScript accepts
// it and the compiled JavaScript is the object literal itself.
//
// UNKNOWN VALUES: a number the core reports that has no name here (a status or
// fidelity code from a newer core) passes through unchanged and compares
// numerically. Each such type is its named members *or any number*.
import type { Span } from "./ffi.ts";

/** A `TWIG_FORMAT_*` code: what a document is parsed as, and what it is
 *  written as. The codes are frozen; a format added later gets the next one.
 *  Every API that takes a format also takes its name (`"md"`, `"gfm"`,
 *  `"svg"`), resolved through {@link formatByName}. */
export const Format = {
  Djot: 1,
  /** twig's Markdown: CommonMark plus the common extensions. */
  Markdown: 2,
  Xml: 3,
  Html: 4,
  AsciiDoc: 5,
  /** Strict CommonMark 0.31.2, a dialect of Markdown. */
  CommonMark: 6,
  /** GitHub-Flavored Markdown, a dialect of Markdown. */
  Gfm: 7,
  /** SVG, a dialect of XML. */
  Svg: 8,
} as const;
export type Format = (typeof Format)[keyof typeof Format] | (number & {});

/** A format, by code or by name. */
export type FormatLike = Format | string;

/** `TWIG_MD_*`: Markdown extensions a parse or an editor turns on, OR-ed
 *  together. Ignored by the other formats. */
export const MarkdownFlags = {
  /** Generic directives: `:name`, `::name`, `:::name`. */
  Directives: 1 << 0,
  /** `$…$` / `$$…$$` math. */
  Math: 1 << 1,
  /** Raw HTML parsed into semantic nodes. */
  HtmlElements: 1 << 2,
  /** `==text==` highlight, a `mark`. */
  Highlight: 1 << 3,
  /** `==🔴 text==`: the circle becomes the mark's `data-color`; brings
   *  {@link MarkdownFlags.Highlight} with it. */
  HighlightColors: 1 << 4,
} as const;

/** A twig C ABI status code. `Ok` is 0; everything else is a failure. */
export const Status = {
  Ok: 0,
  InvalidArgument: 1,
  ParseError: 2,
  OutOfMemory: 3,
  UnsupportedFormat: 4,
  /** A locator resolved to no node, or there is nothing there (no metadata
   *  block, nothing to undo). */
  NotFound: 5,
  /** A selector locator matched more than one node. */
  Ambiguous: 6,
  /** The target node has no editable span or interior. */
  NotEditable: 7,
  /** The edit produced a document that no longer parses; it was rolled
   *  back and nothing changed. */
  EditConflict: 8,
  /** A metadata body its block cannot hold: `</script` or `<!--` in an
   *  HTML `<script>` data island, or a line that closes the block's fence
   *  early (TOML's `+++` inside a multi-line string). */
  UnsafeMetadata: 9,
  InvalidLanguage: 10,
  InternalError: 255,
} as const;
export type Status = (typeof Status)[keyof typeof Status] | (number & {});

const STATUS_NAMES: Record<number, string> = Object.fromEntries(
  Object.entries(Status).map(([name, code]) => [code, name]),
);

/** A failed twig call: `status` is the core's code, `op` the C entry point
 *  that returned it. */
export class TwigError extends Error {
  readonly status: Status;
  readonly op: string;

  constructor(status: Status, op: string, detail?: string) {
    const name = STATUS_NAMES[status] ?? `status ${status}`;
    super(`${op}: ${name}${detail ? ` — ${detail}` : ""}`);
    this.name = "TwigError";
    this.status = status;
    this.op = op;
  }
}

/** Throw a {@link TwigError} unless `status` is `Ok`. */
export function check(status: number, op: string, detail?: string): void {
  if (status !== Status.Ok) throw new TwigError(status, op, detail);
}

export function disposedError(what: string): Error {
  return new Error(`twig: this ${what} has been disposed`);
}

/** `TwigWarning.fidelity`: how a conversion loses a node. */
export const Fidelity = {
  /** The target's parser reads what is written back as a different kind. */
  Degraded: 1,
  /** Nothing of the node is written. */
  Dropped: 2,
  /** Some of the node's attributes are written where they are not read back
   *  as its own. */
  AttrsDegraded: 3,
  /** Some of the node's attributes are not written at all. */
  AttrsDropped: 4,
} as const;
export type Fidelity = (typeof Fidelity)[keyof typeof Fidelity] | (number & {});

/** One thing converting a document to a target would silently lose. */
export interface Warning {
  fidelity: Fidelity;
  /** Child-index trail from the root, `"1/0/2"`; empty for the root. */
  path: string;
  /** The affected node's kind name. */
  kind: string;
}

/** One node a query or hit test matched. Spans are UTF-8 byte offsets into
 *  the source. */
export interface Match {
  id: number;
  kind: string;
  span: Span;
  /** The interior between the node's delimiters; absent for a leaf, or a
   *  container with no contiguous interior. */
  contentSpan?: Span;
}

/** One attribute as written; a `null` value is a bare attribute
 *  (`disabled`). */
export interface Attribute {
  key: string;
  value: string | null;
}

/** One node of the flat tree {@link Document#nodes} returns. Links are ids,
 *  `null` where absent. */
export interface FlatNode {
  id: number;
  kind: string;
  parent: number | null;
  firstChild: number | null;
  nextSibling: number | null;
  span: Span;
  contentSpan?: Span;
  /** The leading bytes a rich view hides: a heading's `#`s, an item's
   *  `- `. */
  markerSpan?: Span;
  /** A heading's level, or a verse line's indent; 0 otherwise. */
  level: number;
  /** The node's text payload (a `text` node's text, a code block's code). */
  text?: string;
  /** A link's or image's destination. */
  destination?: string;
  /** A generic container's tag or directive name. */
  name?: string;
  attributes: Attribute[];
  /** A row's or cell's header flag; absent for other kinds. */
  head?: boolean;
  /** A cell's alignment (`TWIG_ALIGN_*`: 0 default, 1 left, 2 right,
   *  3 center); absent for other kinds. */
  alignment?: number;
  /** A task item's checkbox; absent for other kinds. */
  checked?: boolean;
  /** Which generic-container spelling fits (`TWIG_DIRECTIVE_*`: 0 text,
   *  1 leaf, 2 container); absent when none. */
  directiveForm?: number;
  /** Whether a container was written as a tag (0) or a directive (1);
   *  absent when nothing recorded it. */
  containerOrigin?: number;
}

/** The byte effect of an edit: `oldSpan` of the source before it was
 *  replaced by `newSpan` of the source after. */
export interface Change {
  oldSpan: Span;
  newSpan: Span;
}

/** Which metadata block: the one a document opens with, or the trailing
 *  one (endmatter). An HTML page's `<script type="application/…">` data
 *  island is always `"front"`. */
export type Where = "front" | "end";

/** A located metadata block. Spans are UTF-8 byte offsets. */
export interface MetadataBlock {
  /** The language tag as written: `yaml` for a bare `---`, `toml` for
   *  `+++`, the `<lang>` of `---<lang>` or of `type="application/<lang>"`. */
  lang: string;
  /** The whole block, fences or tags included. */
  span: Span;
  /** The bytes between the fences: what fig edits. */
  bodySpan: Span;
  /** The body's text. */
  body: string;
}
