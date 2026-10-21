// The edit path: lossless, in-place span-splice editing.
//
// An `Editor` holds a private copy of the source and reparses after every
// edit; a failed edit leaves it byte for byte as it was. Edits are addressed
// by a *locator* — a dot-separated child-index path (`"0.3.1"`) or a selector
// that must match exactly one node (`heading("Status")`) — or, for
// `editRange`, by UTF-8 byte offsets. Every edit is one undo step.
import { CHANGE_SIZE, decoder, Frame, handleRegistry, readBytes, readPair, readSpan, readU32, twig } from "./ffi.ts";
import { Document, type ParseOptions, toBytes, whereCode } from "./document.ts";
import { resolveFormat } from "./formats.ts";
import {
  type Change,
  check,
  disposedError,
  type FlatNode,
  type FormatLike,
  type Match,
  type MetadataBlock,
  Status,
  TwigError,
  type Where,
} from "./types.ts";

const REGISTRY = handleRegistry((handle) => twig.twig_editor_destroy(handle));

function readChange(at: number): Change {
  return { oldSpan: readSpan(at), newSpan: readSpan(at + 8) };
}

/** Options for {@link Editor#setMetadata}. */
export interface SetMetadataOptions {
  /** Which block; `"front"` by default. */
  at?: Where;
  /** The language a *new* front block is written in: `yaml` (the default),
   *  `toml`, `json` or `figl`. An existing block keeps its own. */
  lang?: string;
}

/** A lossless editor over one document. Release with
 *  {@link Editor#dispose}. */
export class Editor {
  private handle: number;
  private disposed = false;
  private view: Document | null = null;

  private constructor(handle: number) {
    this.handle = handle;
    REGISTRY?.register(this, handle, this);
  }

  /** Open an editor over `input`, parsed as `format`. Markdown's
   *  {@link MarkdownFlags} decide what the editor reads, and so what its
   *  gestures may write. */
  static create(input: string | Uint8Array, format: FormatLike, options: ParseOptions = {}): Editor {
    const code = resolveFormat(format);
    const frame = new Frame();
    try {
      const { ptr, len } = frame.str(toBytes(input));
      const out = frame.alloc(4);
      check(twig.twig_editor_create_ext(ptr, len, code, options.flags ?? 0, out), "twig_editor_create", `format ${code}`);
      const handle = readU32(out);
      if (handle === 0) throw new TwigError(Status.InternalError, "twig_editor_create");
      return new Editor(handle);
    } finally {
      frame.dispose();
    }
  }

  private live(): number {
    if (this.disposed) throw disposedError("Editor");
    return this.handle;
  }

  /** The current source, as bytes. */
  get bytes(): Uint8Array {
    const frame = new Frame();
    try {
      const out = frame.alloc(8);
      check(twig.twig_editor_source(this.live(), out, out + 4), "twig_editor_source");
      const [ptr, len] = readPair(out);
      return readBytes(ptr, len);
    } finally {
      frame.dispose();
    }
  }

  /** The current source. */
  get source(): string {
    return decoder.decode(this.bytes);
  }

  /** A change token, bumped once per successful edit, undo or redo. */
  get revision(): number {
    return Number(twig.twig_editor_revision(this.live()));
  }

  /** The editor's live tree, as a {@link Document} that stays current
   *  across edits. It reads, queries and walks; it cannot render or
   *  serialize (parse {@link Editor#source} for that). The editor owns it. */
  document(): Document {
    if (this.view) return this.view;
    const frame = new Frame();
    try {
      const out = frame.alloc(4);
      check(twig.twig_editor_document(this.live(), out), "twig_editor_document");
      this.view = new Document(readU32(out), () => this.bytes, true);
      return this.view;
    } finally {
      frame.dispose();
    }
  }

  /** Every node a selector matches in the current tree. */
  query(selector: string): Match[] {
    return this.document().query(selector);
  }

  /** The current tree, flat. */
  nodes(): FlatNode[] {
    return this.document().nodes();
  }

  /** The current tree as twig's AST JSON. */
  ast(): unknown {
    return this.document().ast();
  }

  /** The metadata block at `at` in the current source, or `null`. */
  metadata(at: Where = "front"): MetadataBlock | null {
    return this.document().metadata(at);
  }

  /** The metadata block at `at` in the current source, read as data. */
  metadataValue<T = unknown>(at: Where = "front"): T | null {
    return this.document().metadataValue<T>(at);
  }

  /** Replace the body of the metadata block at `options.at` with `body`,
   *  which must parse as the block's language. On a document with no front
   *  block, write a new one in `options.lang` — above the first line, or in
   *  an HTML page as a `<script type="application/<lang>">` island in
   *  `<head>`. Every byte outside the body is kept. */
  setMetadata(body: string, options: SetMetadataOptions = {}): Change {
    return this.edit("twig_editor_set_metadata", (f, out) => {
      const lang = f.str(options.lang ?? "");
      const text = f.str(body);
      return twig.twig_editor_set_metadata(this.live(), whereCode(options.at ?? "front"), lang.ptr, lang.len, text.ptr, text.len, out);
    });
  }

  /** Splice UTF-8 bytes `[start, end)` of the current source with `text`. */
  editRange(start: number, end: number, text: string): Change {
    return this.edit("twig_editor_edit_range", (f, out) => {
      const t = f.str(text);
      return twig.twig_editor_edit_range(this.live(), start, end, t.ptr, t.len, out);
    });
  }

  /** Replace the located node's whole source with `text`. */
  replace(locator: string, text: string): Change {
    return this.locatorEdit("twig_editor_replace", locator, text, twig.twig_editor_replace);
  }

  /** Replace the located container's interior with `text`. */
  replaceContent(locator: string, text: string): Change {
    return this.locatorEdit("twig_editor_replace_content", locator, text, twig.twig_editor_replace_content);
  }

  /** Insert `text` immediately before the located node. */
  insertBefore(locator: string, text: string): Change {
    return this.locatorEdit("twig_editor_insert_before", locator, text, twig.twig_editor_insert_before);
  }

  /** Insert `text` immediately after the located node. */
  insertAfter(locator: string, text: string): Change {
    return this.locatorEdit("twig_editor_insert_after", locator, text, twig.twig_editor_insert_after);
  }

  /** Insert `text` as the `index`-th child of the located container; an
   *  index past the last child appends. */
  insertChild(locator: string, index: number, text: string): Change {
    return this.edit("twig_editor_insert_child", (f) => {
      const l = f.str(locator);
      const t = f.str(text);
      return twig.twig_editor_insert_child(this.live(), l.ptr, l.len, index, t.ptr, t.len);
    });
  }

  /** Delete the located node. `smart` (the default) tidies the blank lines
   *  around a whole-line node; `false` removes exactly its span. */
  delete(locator: string, options: { smart?: boolean } = {}): Change {
    const smart = options.smart ?? true;
    const op = smart ? "twig_editor_delete_smart" : "twig_editor_delete";
    return this.edit(op, (f) => {
      const l = f.str(locator);
      return (smart ? twig.twig_editor_delete_smart : twig.twig_editor_delete)(this.live(), l.ptr, l.len);
    });
  }

  /** Replace the located node with its interior: drop the wrapper, keep
   *  the children. */
  unwrap(locator: string): Change {
    return this.edit("twig_editor_unwrap", (f) => {
      const l = f.str(locator);
      return twig.twig_editor_unwrap(this.live(), l.ptr, l.len);
    });
  }

  /** Move the located node to just before the node `anchor` locates. */
  moveBefore(locator: string, anchor: string): Change {
    return this.locatorEdit("twig_editor_move_before", locator, anchor, twig.twig_editor_move_before);
  }

  /** Move the located node to just after the node `anchor` locates. */
  moveAfter(locator: string, anchor: string): Change {
    return this.locatorEdit("twig_editor_move_after", locator, anchor, twig.twig_editor_move_after);
  }

  /** Remove every node `drop` matches but those `keep` matches; with
   *  `unwrapKept`, unwrap the survivors. */
  filter(drop: string, options: { keep?: string; unwrapKept?: boolean } = {}): void {
    const frame = new Frame();
    try {
      const d = frame.str(drop);
      const k = options.keep === undefined ? { ptr: 0, len: 0 } : frame.str(options.keep);
      check(twig.twig_editor_filter(this.live(), d.ptr, d.len, k.ptr, k.len, options.unwrapKept ? 1 : 0), "twig_editor_filter", drop);
    } finally {
      frame.dispose();
    }
  }

  /** Undo the last edit; its byte effect, or `null` with nothing to undo. */
  undo(): Change | null {
    return this.history("twig_editor_undo", twig.twig_editor_undo);
  }

  /** Redo the last undone edit; its byte effect, or `null` with nothing to
   *  redo. */
  redo(): Change | null {
    return this.history("twig_editor_redo", twig.twig_editor_redo);
  }

  /** Release the handle. Idempotent. */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.view?.dispose();
    REGISTRY?.unregister(this);
    twig.twig_editor_destroy(this.handle);
  }

  [Symbol.dispose](): void {
    this.dispose();
  }

  /** Run an edit; its change, from `out` or else the editor's last. */
  private edit(op: string, call: (frame: Frame, outChange: number) => number): Change {
    const frame = new Frame();
    try {
      const out = frame.zeroed(CHANGE_SIZE);
      check(call(frame, out), op);
      check(twig.twig_editor_last_change(this.live(), out), "twig_editor_last_change");
      return readChange(out);
    } finally {
      frame.dispose();
    }
  }

  private locatorEdit(
    op: string,
    locator: string,
    text: string,
    fn: (ed: number, loc: number, locLen: number, text: number, textLen: number) => number,
  ): Change {
    return this.edit(op, (f) => {
      const l = f.str(locator);
      const t = f.str(text);
      return fn(this.live(), l.ptr, l.len, t.ptr, t.len);
    });
  }

  private history(op: string, fn: (ed: number, out: number) => number): Change | null {
    const frame = new Frame();
    try {
      const out = frame.zeroed(CHANGE_SIZE);
      const status = fn(this.live(), out);
      if (status === Status.NotFound) return null;
      check(status, op);
      return readChange(out);
    } finally {
      frame.dispose();
    }
  }
}
