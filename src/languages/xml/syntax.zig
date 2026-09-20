//! XML's surface spelling — the table `Editor`'s authoring gestures consult.
//! See `src/syntax.zig` for the model.
//!
//! ── Why XML has a table at all ─────────────────────────────────────────────
//! It used to carry `Syntax.none`, and for every gesture a caret editor makes
//! that is still the honest answer: there is no `**` to toggle, no `> ` to
//! prefix, no fence, and no renderer that could print a heading into a
//! document whose element names mean nothing to twig. `authorable()` is
//! false, and a prose editor over XML opens it read-only.
//!
//! But a caret is not the only thing that edits a document. A tree-shaped
//! editor — a canvas over an SVG, where the user drags a `<rect>` and the
//! edit is its `x` and `y` — needs exactly one thing from the format: the
//! spelling of an element's own attributes, so a change to them splices the
//! start tag and nothing else. `parser.zig` records that span on every
//! element, and the run's shape is XML's own: ` key="value"` pairs, entities
//! for the four bytes that would end a value or a tag. That is the one claim
//! this table makes, and `Editor.setNodeAttrs` is the one gesture it opens.
//!
//! What is still not here, and why: inserting, deleting and reordering an
//! element are not gestures, because they need no spelling — the splicer's
//! node ops (`insertBefore`, `deleteNode`, `moveNode`, …) take the bytes the
//! caller hands them and reparse, and an XML fragment is its own spelling.

const syntax = @import("../../syntax.zig");

pub const table: syntax.Syntax = .{
    .node_attrs = .{ .open = "<" },
};
