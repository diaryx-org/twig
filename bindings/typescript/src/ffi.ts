// Low-level bridge to the twig wasm module.
//
// This file owns the single WebAssembly instance and the marshalling between
// JavaScript values and twig's C ABI (bindings/c/include/twig.h): allocating
// in linear memory, and reading back the borrowed `(ptr, len)` slices and the
// structs the read paths return. Everything above it (Document, Editor) speaks
// in JS types and never touches a pointer.
//
// The module imports nothing and exports its memory. Instantiation is lazy:
// the first FFI call compiles it synchronously (fine under Node and Web
// Workers). A browser main thread forbids synchronous compilation of modules
// >4 KB, so there a caller must `await init()` once before any other call.
import { WASM_BASE64 } from "./wasm-bytes.ts";

/** The exported twig symbols. Every pointer and length is a wasm32 `i32`;
 *  `twig_editor_revision`'s `u64` crosses as `i64` and so is a `bigint`. */
export interface Exports {
  memory: WebAssembly.Memory;
  twig_alloc(len: number): number;
  twig_free(ptr: number, len: number): void;

  twig_abi_version(): number;
  twig_version(): number;
  twig_version_string(): number;
  twig_format_by_name(name: number, nameLen: number, outFormat: number): number;
  twig_format_name(format: number, outPtr: number, outLen: number): number;
  twig_format_dialect_of(format: number, outFormat: number): number;
  twig_format_feature_bit(format: number, name: number, nameLen: number, outBit: number): number;

  twig_parse_ext(input: number, inputLen: number, format: number, flags: number, outDoc: number): number;
  twig_document_destroy(doc: number): void;
  twig_document_render_html(doc: number, outPtr: number, outLen: number): number;
  twig_document_serialize(doc: number, format: number, outPtr: number, outLen: number): number;
  twig_document_ast_json(doc: number, outPtr: number, outLen: number): number;
  twig_document_query(doc: number, sel: number, selLen: number, outPtr: number, outLen: number): number;
  twig_document_diagnostics(doc: number, format: number, outPtr: number, outLen: number): number;
  twig_document_nodes(doc: number, outPtr: number, outLen: number): number;
  twig_document_children(doc: number, node: number, outPtr: number, outLen: number): number;
  twig_document_node_at(doc: number, offset: number, outMatch: number): number;
  twig_document_nodes_at(doc: number, offset: number, outPtr: number, outLen: number): number;
  twig_document_metadata(doc: number, at: number, outSpan: number, outBody: number, outLang: number, outLangLen: number): number;
  twig_document_metadata_json(doc: number, at: number, outPtr: number, outLen: number): number;

  twig_editor_create_ext(input: number, inputLen: number, format: number, flags: number, outEditor: number): number;
  twig_editor_destroy(ed: number): void;
  twig_editor_document(ed: number, outDoc: number): number;
  twig_editor_source(ed: number, outPtr: number, outLen: number): number;
  twig_editor_edit_range(ed: number, start: number, end: number, text: number, textLen: number, outChange: number): number;
  twig_editor_last_change(ed: number, outChange: number): number;
  twig_editor_undo(ed: number, outChange: number): number;
  twig_editor_redo(ed: number, outChange: number): number;
  twig_editor_revision(ed: number): bigint;
  twig_editor_replace(ed: number, loc: number, locLen: number, text: number, textLen: number): number;
  twig_editor_replace_content(ed: number, loc: number, locLen: number, text: number, textLen: number): number;
  twig_editor_insert_before(ed: number, loc: number, locLen: number, text: number, textLen: number): number;
  twig_editor_insert_after(ed: number, loc: number, locLen: number, text: number, textLen: number): number;
  twig_editor_insert_child(ed: number, loc: number, locLen: number, index: number, text: number, textLen: number): number;
  twig_editor_delete(ed: number, loc: number, locLen: number): number;
  twig_editor_delete_smart(ed: number, loc: number, locLen: number): number;
  twig_editor_unwrap(ed: number, loc: number, locLen: number): number;
  twig_editor_move_before(ed: number, loc: number, locLen: number, anchor: number, anchorLen: number): number;
  twig_editor_move_after(ed: number, loc: number, locLen: number, anchor: number, anchorLen: number): number;
  twig_editor_filter(ed: number, drop: number, dropLen: number, keep: number, keepLen: number, unwrapKept: number): number;
  twig_editor_set_metadata(ed: number, at: number, lang: number, langLen: number, body: number, bodyLen: number, outChange: number): number;
}

export function decodeBase64(b64: string): Uint8Array<ArrayBuffer> {
  // `Buffer` under Node; `atob` in the browser. Either way, copy into a fresh
  // ArrayBuffer-backed view so the bytes satisfy `BufferSource` exactly.
  const g = globalThis as { Buffer?: { from(s: string, enc: string): Uint8Array }; atob?(s: string): string };
  if (g.Buffer) return new Uint8Array(g.Buffer.from(b64, "base64"));
  const bin = g.atob!(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// The instance is created lazily so that merely importing the package never
// compiles wasm — which would throw on a browser main thread (sync compile of a
// >4 KB module is disallowed there). `ensure()` does the sync compile on first
// use; `init()` does it asynchronously for the browser.
let exports: Exports | null = null;
let initPromise: Promise<void> | null = null;

/** Compile + instantiate the twig wasm module, synchronously. Return its
 *  exports or throw a guidance error (the browser-main-thread case). */
function ensure(): Exports {
  if (exports) return exports;
  try {
    const instance = new WebAssembly.Instance(new WebAssembly.Module(decodeBase64(WASM_BASE64)), {});
    exports = instance.exports as unknown as Exports;
  } catch (err) {
    throw new Error(
      "twig: the WebAssembly module failed to initialize synchronously. On a " +
        "browser main thread, call `await init()` once at startup before using " +
        "any twig API (synchronous compilation of modules larger than 4 KB is " +
        "disallowed there). Underlying error: " +
        (err instanceof Error ? err.message : String(err)),
    );
  }
  return exports;
}

/** Asynchronously compile + instantiate the twig wasm module. Safe to call
 *  anywhere — including a browser main thread — and idempotent (concurrent
 *  calls share one instantiation). Optional under Node and in Web Workers,
 *  where the module also initializes lazily on first use. Once it resolves,
 *  every twig API is usable synchronously. */
export function init(): Promise<void> {
  if (exports) return Promise.resolve();
  if (initPromise) return initPromise;
  initPromise = WebAssembly.instantiate(decodeBase64(WASM_BASE64), {}).then(({ instance }) => {
    exports = instance.exports as unknown as Exports;
  });
  return initPromise;
}

/** True once the wasm module is instantiated (after `init()` or a first sync
 *  call). Lets a browser caller check without triggering a sync compile. */
export function isReady(): boolean {
  return exports !== null;
}

// A Proxy so every `twig.twig_*` call site lazily triggers `ensure()` on first
// property access.
export const twig: Exports = new Proxy({} as Exports, {
  get(_target, prop) {
    return ensure()[prop as keyof Exports];
  },
}) as Exports;

export const encoder = new TextEncoder();
// `ignoreBOM`: what the core hands back is text as it stands — an editor's
// source keeps the byte-order mark it opened with — and a WHATWG decoder
// would otherwise drop one at the start of a slice.
export const decoder = new TextDecoder("utf-8", { fatal: false, ignoreBOM: true });

/** A fresh view over linear memory. `memory.grow` detaches the old buffer, so
 *  a view must be re-derived after any allocation rather than cached. */
export function u8(): Uint8Array {
  return new Uint8Array(ensure().memory.buffer);
}
export function dv(): DataView {
  return new DataView(ensure().memory.buffer);
}

/** A scratch arena: every allocation made through a frame is freed together
 *  by `dispose`, so an FFI call's transient buffers never leak even on a
 *  throw. */
export class Frame {
  private allocs: Array<[number, number]> = [];

  /** Allocate `len` uninitialized bytes (pointer 0 for an empty request). */
  alloc(len: number): number {
    if (len === 0) return 0;
    const ptr = ensure().twig_alloc(len);
    if (ptr === 0) throw new Error("twig_alloc: out of memory");
    this.allocs.push([ptr, len]);
    return ptr;
  }

  /** Allocate `len` zeroed bytes. */
  zeroed(len: number): number {
    const ptr = this.alloc(len);
    if (ptr !== 0) u8().fill(0, ptr, ptr + len);
    return ptr;
  }

  /** Copy `data` into freshly allocated memory; returns its pointer (0 if
   *  empty). */
  bytes(data: Uint8Array): number {
    const ptr = this.alloc(data.length);
    if (ptr !== 0) u8().set(data, ptr);
    return ptr;
  }

  /** UTF-8 encode `s` (or take bytes as they are) into memory. */
  str(s: string | Uint8Array): { ptr: number; len: number } {
    const data = typeof s === "string" ? encoder.encode(s) : s;
    return { ptr: this.bytes(data), len: data.length };
  }

  dispose(): void {
    if (this.allocs.length === 0) return;
    const free = ensure().twig_free;
    for (const [ptr, len] of this.allocs) free(ptr, len);
    this.allocs.length = 0;
  }
}

export function readU32(ptr: number): number {
  return dv().getUint32(ptr, true);
}

export function readI32(ptr: number): number {
  return dv().getInt32(ptr, true);
}

/** The bytes at `(ptr, len)`, copied out of linear memory. */
export function readBytes(ptr: number, len: number): Uint8Array {
  if (len === 0 || ptr === 0) return new Uint8Array();
  return u8().slice(ptr, ptr + len);
}

/** The UTF-8 text at `(ptr, len)`. */
export function readText(ptr: number, len: number): string {
  if (len === 0 || ptr === 0) return "";
  return decoder.decode(u8().subarray(ptr, ptr + len));
}

/** The `(ptr, len)` pair an out-param scratch of 8 bytes holds. */
export function readPair(scratch: number): [number, number] {
  const view = dv();
  return [view.getUint32(scratch, true), view.getUint32(scratch + 4, true)];
}

/** Read a NUL-terminated C string from linear memory. */
export function readCString(ptr: number): string {
  if (ptr === 0) return "";
  const mem = u8();
  let end = ptr;
  while (mem[end] !== 0) end++;
  return decoder.decode(mem.subarray(ptr, end));
}

/** Build a FinalizationRegistry that frees a native handle when its JS
 *  wrapper is garbage-collected without an explicit `dispose()` — a leak
 *  backstop, not a substitute for `using`/`dispose()` (GC timing is
 *  unspecified). `null` on a runtime without FinalizationRegistry. */
export function handleRegistry(destroy: (handle: number) => void): FinalizationRegistry<number> | null {
  return typeof FinalizationRegistry !== "undefined" ? new FinalizationRegistry(destroy) : null;
}

// ── struct layouts on wasm32 ────────────────────────────────────────────────
// `size_t` and every pointer are 4 bytes here, so these differ from the
// 64-bit offsets twig.h's comments assume. twig-capi asserts the same
// numbers at compile time for a 32-bit target (src/lib.rs).

/** `TwigSpan { size_t start, end; }`. */
export const SPAN_SIZE = 8;
/** `TwigChange { TwigSpan old_span, new_span; }`. */
export const CHANGE_SIZE = 16;
/** `TwigQueryMatch`: node_id 0, span 4, content_span 12, has_content_span
 *  20, kind 24. */
export const MATCH_SIZE = 28;
/** `TwigWarning`: fidelity 0, path 4/8, kind 12. */
export const WARNING_SIZE = 16;
/** `TwigKeyVal`: key 0/4, value 8/12. */
export const KEYVAL_SIZE = 16;
/** `TwigFlatNode`; offsets below. */
export const FLAT_NODE_SIZE = 108;

/** A byte range `[start, end)` into the source, in UTF-8 bytes. */
export interface Span {
  start: number;
  end: number;
}

export function readSpan(ptr: number): Span {
  const view = dv();
  return { start: view.getUint32(ptr, true), end: view.getUint32(ptr + 4, true) };
}
