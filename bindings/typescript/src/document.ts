// The read path: parse a document, then render, convert, query or walk it.
//
// `Document` owns a parsed handle and must be released with `dispose` (or a
// `using` declaration). Every span is a UTF-8 byte offset into the source,
// as the core counts; `Document#text` slices the source by one.
import {
  dv,
  encoder,
  decoder,
  FLAT_NODE_SIZE,
  Frame,
  handleRegistry,
  KEYVAL_SIZE,
  MATCH_SIZE,
  readCString,
  readPair,
  readSpan,
  readText,
  readU32,
  SPAN_SIZE,
  twig,
  WARNING_SIZE,
  type Span,
} from "./ffi.ts";
import { resolveFormat } from "./formats.ts";
import {
  check,
  disposedError,
  type FlatNode,
  type FormatLike,
  type Match,
  type MetadataBlock,
  Status,
  TwigError,
  type Warning,
  type Where,
} from "./types.ts";

const NO_NODE = 0xffffffff;

// Frees the handle of a Document dropped without dispose(). A backstop only —
// `using`/`dispose()` remains the deterministic path.
const REGISTRY = handleRegistry((handle) => twig.twig_document_destroy(handle));

/** Options for {@link Document.parse} and {@link Editor.create}. */
export interface ParseOptions {
  /** {@link MarkdownFlags} OR-ed together, or a runtime format's feature
   *  bits. */
  flags?: number;
}

export function toBytes(input: string | Uint8Array): Uint8Array {
  return typeof input === "string" ? encoder.encode(input) : input;
}

export function whereCode(at: Where): number {
  if (at === "front") return 0;
  if (at === "end") return 1;
  throw new TwigError(Status.InvalidArgument, "metadata", `\`at\` is "front" or "end", not ${JSON.stringify(at)}`);
}

/** A parsed, read-only document. Release with {@link Document#dispose}. */
export class Document {
  private handle: number;
  private disposed = false;
  private readonly source: () => Uint8Array;
  private readonly borrowed: boolean;

  /** @internal Wrap a handle: owned (destroyed with the wrapper) or
   *  borrowed from an editor (`source` reads the editor's bytes). */
  constructor(handle: number, source: Uint8Array | (() => Uint8Array), borrowed = false) {
    this.handle = handle;
    this.source = typeof source === "function" ? source : () => source;
    this.borrowed = borrowed;
    if (!borrowed) REGISTRY?.register(this, handle, this);
  }

  /** Parse `input` as `format` (a {@link Format} code or a name such as
   *  `"md"`). A document whose frontmatter carries `twig` settings is read
   *  as they ask. */
  static parse(input: string | Uint8Array, format: FormatLike, options: ParseOptions = {}): Document {
    const code = resolveFormat(format);
    const bytes = toBytes(input).slice();
    const frame = new Frame();
    try {
      const { ptr, len } = frame.str(bytes);
      const out = frame.alloc(4);
      check(twig.twig_parse_ext(ptr, len, code, options.flags ?? 0, out), "twig_parse", `format ${code}`);
      const handle = readU32(out);
      if (handle === 0) throw new TwigError(Status.InternalError, "twig_parse");
      return new Document(handle, bytes);
    } finally {
      frame.dispose();
    }
  }

  /** @internal */
  live(): number {
    if (this.disposed) throw disposedError("Document");
    return this.handle;
  }

  /** The source this document was parsed from. */
  get bytes(): Uint8Array {
    this.live();
    return this.source();
  }

  /** The source this document was parsed from, as text. */
  get sourceText(): string {
    return decoder.decode(this.bytes);
  }

  /** The source text a span covers. */
  text(span: Span): string {
    return decoder.decode(this.bytes.subarray(span.start, span.end));
  }

  /** Render to HTML. Not available on an editor's view: render
   *  `editor.source` instead. */
  renderHtml(): string {
    return this.readOut((p, l) => twig.twig_document_render_html(this.live(), p, l), "twig_document_render_html");
  }

  /** Write the document in `format`'s own syntax: a round trip for its own
   *  format, a conversion for another. {@link Document#diagnostics} says what
   *  a conversion would lose. */
  serialize(format: FormatLike): string {
    const code = resolveFormat(format);
    return this.readOut((p, l) => twig.twig_document_serialize(this.live(), code, p, l), "twig_document_serialize");
  }

  /** The AST as twig encodes it for `twig convert -o ast`. */
  ast(): unknown {
    return JSON.parse(this.astJson());
  }

  /** The AST as pretty-printed JSON text. */
  astJson(): string {
    return this.readOut((p, l) => twig.twig_document_ast_json(this.live(), p, l), "twig_document_ast_json");
  }

  /** Every node a CSS-lite selector matches, in document order:
   *  `heading[level=2]`, `link[dest^="http"]`, `list > item`. */
  query(selector: string): Match[] {
    const frame = new Frame();
    try {
      const sel = frame.str(selector);
      const out = frame.alloc(8);
      check(twig.twig_document_query(this.live(), sel.ptr, sel.len, out, out + 4), "twig_document_query", selector);
      return readMatches(out);
    } finally {
      frame.dispose();
    }
  }

  /** What converting this document to `format` would silently lose; empty
   *  for a lossless conversion. */
  diagnostics(format: FormatLike): Warning[] {
    const code = resolveFormat(format);
    const frame = new Frame();
    try {
      const out = frame.alloc(8);
      check(twig.twig_document_diagnostics(this.live(), code, out, out + 4), "twig_document_diagnostics");
      const [ptr, len] = readPair(out);
      const view = dv();
      const warnings: Warning[] = [];
      for (let i = 0; i < len; i++) {
        const at = ptr + i * WARNING_SIZE;
        warnings.push({
          fidelity: view.getInt32(at, true),
          path: readText(view.getUint32(at + 4, true), view.getUint32(at + 8, true)),
          kind: readCString(view.getUint32(at + 12, true)),
        });
      }
      return warnings;
    } finally {
      frame.dispose();
    }
  }

  /** The whole tree as a flat array, indexed so `nodes[i].id === i`. The
   *  root is node 0's ancestor with no parent; a footnote or link-reference
   *  definition is a node with no parent too. */
  nodes(): FlatNode[] {
    const frame = new Frame();
    try {
      const out = frame.alloc(8);
      check(twig.twig_document_nodes(this.live(), out, out + 4), "twig_document_nodes");
      const [ptr, len] = readPair(out);
      const nodes: FlatNode[] = [];
      for (let i = 0; i < len; i++) nodes.push(readFlatNode(ptr + i * FLAT_NODE_SIZE));
      return nodes;
    } finally {
      frame.dispose();
    }
  }

  /** The direct children of node `id`, or of the document root when `id`
   *  is omitted. */
  children(id?: number): Match[] {
    const frame = new Frame();
    try {
      const out = frame.alloc(8);
      check(twig.twig_document_children(this.live(), id ?? NO_NODE, out, out + 4), "twig_document_children");
      return readMatches(out);
    } finally {
      frame.dispose();
    }
  }

  /** The deepest node whose span holds byte `offset`, or `null`. */
  nodeAt(offset: number): Match | null {
    const frame = new Frame();
    try {
      const out = frame.zeroed(MATCH_SIZE);
      const status = twig.twig_document_node_at(this.live(), offset, out);
      if (status === Status.NotFound) return null;
      check(status, "twig_document_node_at");
      return readMatch(out);
    } finally {
      frame.dispose();
    }
  }

  /** Every node holding byte `offset`, root first. */
  nodesAt(offset: number): Match[] {
    const frame = new Frame();
    try {
      const out = frame.alloc(8);
      const status = twig.twig_document_nodes_at(this.live(), offset, out, out + 4);
      if (status === Status.NotFound) return [];
      check(status, "twig_document_nodes_at");
      return readMatches(out);
    } finally {
      frame.dispose();
    }
  }

  /** The metadata block at `at` — frontmatter, endmatter, or an HTML page's
   *  `<script type="application/…">` data island — or `null` when there is
   *  none. Edit its {@link MetadataBlock#body} with `@diaryx/fig` to keep
   *  its comments, then write it back with {@link Editor#setMetadata}. */
  metadata(at: Where = "front"): MetadataBlock | null {
    const frame = new Frame();
    try {
      const spans = frame.zeroed(2 * SPAN_SIZE);
      const lang = frame.zeroed(8);
      const status = twig.twig_document_metadata(this.live(), whereCode(at), spans, spans + SPAN_SIZE, lang, lang + 4);
      if (status === Status.NotFound) return null;
      check(status, "twig_document_metadata");
      const span = readSpan(spans);
      const bodySpan = readSpan(spans + SPAN_SIZE);
      const [langPtr, langLen] = readPair(lang);
      return { lang: readText(langPtr, langLen), span, bodySpan, body: this.text(bodySpan) };
    } finally {
      frame.dispose();
    }
  }

  /** The metadata block at `at`, read as data: the body parsed in its
   *  language (YAML, TOML, JSON or figl) and handed back as plain
   *  JavaScript, or `null` when there is no block. A value JSON cannot
   *  spell (a TOML datetime) comes back as fig's `{"$fig": …}` envelope. */
  metadataValue<T = unknown>(at: Where = "front"): T | null {
    const frame = new Frame();
    try {
      const out = frame.alloc(8);
      const status = twig.twig_document_metadata_json(this.live(), whereCode(at), out, out + 4);
      if (status === Status.NotFound) return null;
      check(status, "twig_document_metadata_json");
      const [ptr, len] = readPair(out);
      return JSON.parse(readText(ptr, len)) as T;
    } finally {
      frame.dispose();
    }
  }

  /** Release the handle. Idempotent. A view borrowed from an editor is the
   *  editor's to free; disposing it only stops this wrapper. */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    if (this.borrowed) return;
    REGISTRY?.unregister(this);
    twig.twig_document_destroy(this.handle);
  }

  [Symbol.dispose](): void {
    this.dispose();
  }

  private readOut(call: (outPtr: number, outLen: number) => number, op: string): string {
    const frame = new Frame();
    try {
      const out = frame.alloc(8);
      check(call(out, out + 4), op);
      const [ptr, len] = readPair(out);
      return readText(ptr, len);
    } finally {
      frame.dispose();
    }
  }
}

function readMatch(at: number): Match {
  const view = dv();
  const match: Match = {
    id: view.getUint32(at, true),
    kind: readCString(view.getUint32(at + 24, true)),
    span: readSpan(at + 4),
  };
  if (view.getInt32(at + 20, true) !== 0) match.contentSpan = readSpan(at + 12);
  return match;
}

/** The `TwigQueryMatch` array an `(ptr, len)` out pair at `out` points at. */
export function readMatches(out: number): Match[] {
  const [ptr, len] = readPair(out);
  const matches: Match[] = [];
  for (let i = 0; i < len; i++) matches.push(readMatch(ptr + i * MATCH_SIZE));
  return matches;
}

const link = (id: number): number | null => (id === NO_NODE ? null : id);

/** Read a borrowed string field: `undefined` for a NULL pointer. */
function optionalText(ptr: number, len: number): string | undefined {
  return ptr === 0 ? undefined : readText(ptr, len);
}

function readFlatNode(at: number): FlatNode {
  const view = dv();
  const i32 = (off: number): number => view.getInt32(at + off, true);
  const u32 = (off: number): number => view.getUint32(at + off, true);
  const node: FlatNode = {
    id: u32(0),
    kind: readCString(u32(40)),
    parent: link(u32(4)),
    firstChild: link(u32(8)),
    nextSibling: link(u32(12)),
    span: readSpan(at + 16),
    level: u32(36),
    attributes: [],
  };
  if (i32(32) !== 0) node.contentSpan = readSpan(at + 24);
  if (i32(100) !== 0) node.markerSpan = readSpan(at + 92);
  const text = optionalText(u32(44), u32(48));
  if (text !== undefined) node.text = text;
  const destination = optionalText(u32(52), u32(56));
  if (destination !== undefined) node.destination = destination;
  const name = optionalText(u32(68), u32(72));
  if (name !== undefined) node.name = name;
  if (i32(60) >= 0) node.head = i32(60) !== 0;
  if (i32(64) >= 0) node.alignment = i32(64);
  if (i32(104) >= 0) node.checked = i32(104) !== 0;
  if (i32(84) >= 0) node.directiveForm = i32(84);
  if (i32(88) >= 0) node.containerOrigin = i32(88);
  const attrs = u32(76);
  const count = u32(80);
  for (let i = 0; i < count; i++) {
    const kv = attrs + i * KEYVAL_SIZE;
    const valuePtr = view.getUint32(kv + 8, true);
    node.attributes.push({
      key: readText(view.getUint32(kv, true), view.getUint32(kv + 4, true)),
      value: valuePtr === 0 ? null : readText(valuePtr, view.getUint32(kv + 12, true)),
    });
  }
  return node;
}
