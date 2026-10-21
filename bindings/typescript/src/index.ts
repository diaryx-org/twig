// twig — parsing, querying, lossless in-place editing and conversion of
// Djot, Markdown (CommonMark, GFM), HTML, XML (SVG) and AsciiDoc documents,
// and their frontmatter — backed by the twig core compiled to WebAssembly.
//
// The module loads synchronously and imports nothing host-specific, so it
// works identically in Node and the browser.
export {
  Format,
  MarkdownFlags,
  Status,
  Fidelity,
  TwigError,
  type FormatLike,
  type Warning,
  type Match,
  type Attribute,
  type FlatNode,
  type Change,
  type Where,
  type MetadataBlock,
} from "./types.ts";
export type { Span } from "./ffi.ts";
export { init, isReady } from "./ffi.ts";
export { ABI_VERSION, version, versionString, abiVersion, formatByName, formatName, dialectOf, type Version } from "./formats.ts";
export { Document, type ParseOptions } from "./document.ts";
export { Editor, type SetMetadataOptions } from "./editor.ts";

import { Document, type ParseOptions } from "./document.ts";
import { Editor, type SetMetadataOptions } from "./editor.ts";
import type { FormatLike, MetadataBlock, Where } from "./types.ts";

/** Render `input` to HTML in one call. */
export function renderHtml(input: string | Uint8Array, format: FormatLike, options?: ParseOptions): string {
  const doc = Document.parse(input, format, options);
  try {
    return doc.renderHtml();
  } finally {
    doc.dispose();
  }
}

/** Convert `input` from `from` to `to` in one call (`convert(md, "md",
 *  "djot")`). `Document#diagnostics` says what a conversion would lose. */
export function convert(input: string | Uint8Array, from: FormatLike, to: FormatLike, options?: ParseOptions): string {
  const doc = Document.parse(input, from, options);
  try {
    return doc.serialize(to);
  } finally {
    doc.dispose();
  }
}

/** Parse `input` and return twig's AST as plain JavaScript. */
export function parseAst(input: string | Uint8Array, format: FormatLike, options?: ParseOptions): unknown {
  const doc = Document.parse(input, format, options);
  try {
    return doc.ast();
  } finally {
    doc.dispose();
  }
}

/** The metadata block at `at` of `input` — its language, spans and body —
 *  or `null` when there is none. */
export function readMetadata(input: string | Uint8Array, format: FormatLike, at: Where = "front"): MetadataBlock | null {
  const doc = Document.parse(input, format);
  try {
    return doc.metadata(at);
  } finally {
    doc.dispose();
  }
}

/** The metadata block at `at` of `input`, parsed as data — the frontmatter
 *  as an object — or `null` when there is none. */
export function metadataValue<T = unknown>(input: string | Uint8Array, format: FormatLike, at: Where = "front"): T | null {
  const doc = Document.parse(input, format);
  try {
    return doc.metadataValue<T>(at);
  } finally {
    doc.dispose();
  }
}

/** `input` with the body of its metadata block replaced by `body` (or a
 *  new front block written to hold it); every other byte kept. */
export function setMetadata(input: string | Uint8Array, format: FormatLike, body: string, options?: SetMetadataOptions): string {
  const editor = Editor.create(input, format);
  try {
    editor.setMetadata(body, options);
    return editor.source;
  } finally {
    editor.dispose();
  }
}
