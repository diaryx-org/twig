//! HTML: port of `src/languages/html/html.zig`. A forgiving HTML parser
//! (`parser`) and a generic `Ast` -> HTML text renderer (`serializer`). The
//! parser feeds generic markup into the shared AST; the serializer also
//! covers the full semantic vocabulary (it is what the djot and Markdown HTML
//! renderers drive).

pub mod serializer;

pub use serializer::{
    is_void_element, serialize, serialize_alloc, serialize_alloc_opts, serialize_node, serialize_node_opts,
    serialize_opts, write_element_text, Context, RenderAllocError, RenderError, RenderOptions, Renderer, KV,
};

// Twig prints three markdown-family dialects DISTINCTLY, and these two presets
// (plus `RenderOptions::DEFAULT`, which is djot's) are where that lives:
//
//   djot       — djot.js's conventions: bare `<tr>`, `style="text-align:"`,
//                `<ul class="task-list">`. The defaults.
//   markdown   — `COMMONMARK_RENDER_OPTIONS`: CommonMark's core conventions,
//                plus well-formed `<thead>`/`<tbody>` tables.
//   GFM        — `GFM_RENDER_OPTIONS`: the above, plus cmark-gfm's own
//                extension spellings.

/// The HTML render conventions twig-markdown uses: CommonMark's reference
/// output plus `<thead>`/`<tbody>` table sectioning.
pub const COMMONMARK_RENDER_OPTIONS: RenderOptions = RenderOptions {
    xhtml_void: true,
    commonmark_image_attrs: true,
    commonmark_lists: true,
    escape_text_quotes: true,
    percent_encode_urls: true,
    table_sections: true,
    ..RenderOptions::DEFAULT
};

/// GFM's render conventions: a SUPERSET of `COMMONMARK_RENDER_OPTIONS` plus
/// presentational `align=`, cmark-gfm's task-list `<input>`, and the tagfilter.
pub const GFM_RENDER_OPTIONS: RenderOptions = RenderOptions {
    gfm_cell_align_attr: true,
    gfm_task_list_items: true,
    tagfilter: true,
    ..COMMONMARK_RENDER_OPTIONS
};

/// Small documents exercising the shared engine contract; not a conformance corpus.
pub const SAMPLES: &[&[u8]] = &[
    b"",
    b"<p>A paragraph with <em>emphasis</em> and <strong>strong</strong> text.</p>\n",
    b"<h1>Heading</h1>\n",
    b"<p id=\"intro\" class=\"note\">Text &amp; more.</p>\n",
];
