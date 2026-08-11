//! A deliberately small, forgiving HTML tokenizer and tree builder.  It is
//! not a browser-grade implementation of the HTML parsing algorithm, but it
//! does the useful, unsurprising parts for document conversion: HTML syntax,
//! character references, void elements, raw-text/RCDATA elements, and the
//! common optional end tags.  Unlike the XML parser, malformed input is
//! recovered into a best-effort tree instead of being rejected.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Node = AST.Node;
const Span = @import("../../span.zig");

pub const ParseError = Allocator.Error;

pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize = 0,
    builder: AST.Builder,
    /// Reusable buffer for the one child-list rewrite that GROWS the list —
    /// splicing a `<tbody>`'s rows into its table (see `flattenRowGroups`).
    /// Every other rewrite here shrinks in place. Safe to share across tables,
    /// nested ones included: `parseElement` hands the slice straight to
    /// `addContainer`, which copies the ids out before any other element's
    /// `semanticKind` runs.
    row_scratch: std.ArrayList(Node.Id) = .empty,

    pub fn init(allocator: Allocator, source: []const u8) Parser {
        return .{ .allocator = allocator, .source = source, .builder = AST.Builder.init(allocator) };
    }

    pub fn deinit(self: *Parser) void {
        self.row_scratch.deinit(self.allocator);
        self.builder.deinit();
    }

    pub fn parse(self: *Parser) ParseError!Document {
        const children = try self.parseChildren(null);
        defer self.allocator.free(children);
        const doc = try self.builder.addContainer(.doc, self.dropFormattingWhitespace(children));
        self.builder.setSpan(doc, Span.init(0, self.source.len));
        return self.builder.finishDocument(self.source, doc);
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0c';
    }

    fn isNameByte(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == ':' or c == '_' or c == '-';
    }

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.source.len and isSpace(self.source[self.pos])) self.pos += 1;
    }

    fn atIgnoreCase(self: *Parser, needle: []const u8) bool {
        return self.pos + needle.len <= self.source.len and
            std.ascii.eqlIgnoreCase(self.source[self.pos..][0..needle.len], needle);
    }

    fn lowerDup(self: *Parser, text: []const u8) Allocator.Error![]u8 {
        const out = try self.allocator.alloc(u8, text.len);
        for (text, out) |c, *dst| dst.* = std.ascii.toLower(c);
        return out;
    }

    fn readNameLower(self: *Parser) ParseError![]u8 {
        const start = self.pos;
        while (self.pos < self.source.len and isNameByte(self.source[self.pos])) self.pos += 1;
        // Callers only use this after checking the first byte; treating an
        // odd punctuation byte as text is handled before reaching here.
        return self.lowerDup(self.source[start..self.pos]);
    }

    fn endTagMatches(self: *Parser, name: []const u8) bool {
        if (self.pos + 3 > self.source.len or self.source[self.pos] != '<' or self.source[self.pos + 1] != '/') return false;
        var i = self.pos + 2;
        const start = i;
        while (i < self.source.len and isNameByte(self.source[i])) i += 1;
        return i > start and std.ascii.eqlIgnoreCase(self.source[start..i], name) and
            (i == self.source.len or isSpace(self.source[i]) or self.source[i] == '>');
    }

    fn consumeEndTag(self: *Parser) void {
        self.pos += 2;
        while (self.pos < self.source.len and isNameByte(self.source[self.pos])) self.pos += 1;
        while (self.pos < self.source.len and self.source[self.pos] != '>') self.pos += 1;
        if (self.pos < self.source.len) self.pos += 1;
    }

    fn isVoid(name: []const u8) bool {
        return std.mem.eql(u8, name, "area") or std.mem.eql(u8, name, "base") or
            std.mem.eql(u8, name, "br") or std.mem.eql(u8, name, "col") or
            std.mem.eql(u8, name, "embed") or std.mem.eql(u8, name, "hr") or
            std.mem.eql(u8, name, "img") or std.mem.eql(u8, name, "input") or
            std.mem.eql(u8, name, "link") or std.mem.eql(u8, name, "meta") or
            std.mem.eql(u8, name, "param") or std.mem.eql(u8, name, "source") or
            std.mem.eql(u8, name, "track") or std.mem.eql(u8, name, "wbr");
    }

    fn isRawText(name: []const u8) bool {
        return std.mem.eql(u8, name, "script") or std.mem.eql(u8, name, "style") or
            std.mem.eql(u8, name, "xmp") or std.mem.eql(u8, name, "iframe") or
            std.mem.eql(u8, name, "noembed") or std.mem.eql(u8, name, "noframes") or
            std.mem.eql(u8, name, "plaintext");
    }

    fn isRcdata(name: []const u8) bool {
        return std.mem.eql(u8, name, "textarea") or std.mem.eql(u8, name, "title");
    }

    /// Enough of HTML's optional-end-tag rules to make ordinary hand-authored
    /// HTML tree correctly (the rules people encounter most often in lists,
    /// paragraphs, tables, and select menus).
    fn implicitlyCloses(parent: []const u8, child: []const u8) bool {
        if (std.mem.eql(u8, parent, "li")) return std.mem.eql(u8, child, "li");
        if (std.mem.eql(u8, parent, "dt") or std.mem.eql(u8, parent, "dd"))
            return std.mem.eql(u8, child, "dt") or std.mem.eql(u8, child, "dd");
        if (std.mem.eql(u8, parent, "p")) return isBlockStart(child);
        if (std.mem.eql(u8, parent, "rt") or std.mem.eql(u8, parent, "rp"))
            return std.mem.eql(u8, child, "rt") or std.mem.eql(u8, child, "rp");
        if (std.mem.eql(u8, parent, "option")) return std.mem.eql(u8, child, "option") or std.mem.eql(u8, child, "optgroup");
        if (std.mem.eql(u8, parent, "optgroup")) return std.mem.eql(u8, child, "optgroup");
        if (std.mem.eql(u8, parent, "thead") or std.mem.eql(u8, parent, "tbody")) return std.mem.eql(u8, child, "tbody") or std.mem.eql(u8, child, "tfoot");
        if (std.mem.eql(u8, parent, "tr")) return std.mem.eql(u8, child, "tr");
        if (std.mem.eql(u8, parent, "td") or std.mem.eql(u8, parent, "th")) return std.mem.eql(u8, child, "td") or std.mem.eql(u8, child, "th");
        return false;
    }

    fn isBlockStart(name: []const u8) bool {
        const names = [_][]const u8{ "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "menu", "nav", "ol", "p", "pre", "section", "table", "ul" };
        for (names) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    fn parseChildren(self: *Parser, parent: ?[]const u8) ParseError![]Node.Id {
        var children = std.ArrayList(Node.Id).empty;
        errdefer children.deinit(self.allocator);
        while (self.pos < self.source.len) {
            if (self.source[self.pos] != '<') {
                if (try self.parseTextUntil(self.source.len, true)) |id| try children.append(self.allocator, id);
                continue;
            }
            if (self.atIgnoreCase("<!--")) {
                try children.append(self.allocator, try self.parseComment());
            } else if (self.atIgnoreCase("<!doctype")) {
                try children.append(self.allocator, try self.parseDoctype());
            } else if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '?') {
                try children.append(self.allocator, try self.parseProcessingInstruction());
            } else if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                // Let every nested parser see a close tag.  The matching
                // ancestor consumes it; this is essential after an implicit
                // close such as `<ul><li>one<li>two</ul>`.
                if (parent != null) break;
                // A stray close tag is ignored by HTML parsers.  Consume it
                // so recovery always makes progress.
                self.consumeEndTag();
            } else if (self.pos + 1 < self.source.len and isNameByte(self.source[self.pos + 1])) {
                const start = self.pos + 1;
                var end = start;
                while (end < self.source.len and isNameByte(self.source[end])) end += 1;
                if (parent) |name| if (implicitlyCloses(name, self.source[start..end])) break;
                try children.append(self.allocator, try self.parseElement());
            } else if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '!') {
                // HTML calls unknown declarations "bogus comments".
                try children.append(self.allocator, try self.parseBogusComment());
            } else {
                const start = self.pos;
                self.pos += 1;
                const id = try self.builder.addLeaf(.{ .str = self.source[start..self.pos] });
                self.builder.setSpan(id, Span.init(start, self.pos));
                try children.append(self.allocator, id);
            }
        }
        return children.toOwnedSlice(self.allocator);
    }

    fn parseElement(self: *Parser) ParseError!Node.Id {
        const start = self.pos;
        self.pos += 1;
        const name = try self.readNameLower();
        defer self.allocator.free(name);
        const attrs = try self.parseAttributes();
        defer self.freeAttrs(attrs);

        var self_closing = false;
        if (self.pos < self.source.len and self.source[self.pos] == '/') {
            self_closing = true;
            self.pos += 1;
            self.skipSpace();
        }
        if (self.pos < self.source.len and self.source[self.pos] == '>') self.pos += 1;
        const content_start = self.pos;

        if (self_closing or isVoid(name)) {
            var no_children: []Node.Id = &.{};
            const kind = try self.semanticKind(name, attrs, &no_children);
            // `semanticKind` may synthesize children for a void element (e.g.
            // an `<img>`'s alt text becomes the image node's content, which is
            // how the shared model carries alt). Free any such allocation
            // after the builder has copied the child links out.
            defer if (no_children.len > 0) self.allocator.free(no_children);
            const id = try self.builder.addContainer(kind, no_children);
            self.builder.setSpan(id, Span.init(start, self.pos));
            try self.builder.setAttrs(id, .{ .entries = attrs });
            return id;
        }

        var children: []Node.Id = undefined;
        var content_end = self.pos;
        if (isRawText(name) or isRcdata(name)) {
            const raw_start = self.pos;
            const end = self.rawTextEnd(name);
            self.pos = end;
            if (try self.parseTextRange(raw_start, end, isRcdata(name))) |id| {
                children = try self.allocator.dupe(Node.Id, &.{id});
            } else children = try self.allocator.alloc(Node.Id, 0);
            content_end = self.pos;
            if (self.pos < self.source.len and self.endTagMatches(name)) self.consumeEndTag();
        } else {
            children = try self.parseChildren(name);
            content_end = self.pos;
            if (self.pos < self.source.len and self.endTagMatches(name)) self.consumeEndTag();
        }
        // `semanticKind` may shrink `children` to a sub-slice (dropping layout
        // whitespace, wrapping list items). Free the *original* allocation —
        // freeing a length-shrunk view mismatches the allocator's size class.
        const owned_children = children;
        defer self.allocator.free(owned_children);

        const kind = try self.semanticKind(name, attrs, &children);
        const id = try self.builder.addContainer(kind, children);
        self.builder.setSpan(id, Span.init(start, self.pos));
        self.builder.setContentSpan(id, Span.init(content_start, content_end));
        try self.builder.setAttrs(id, .{ .entries = attrs });
        return id;
    }

    /// Map the subset of HTML that Twig's own HTML renderer emits back to the
    /// shared semantic vocabulary.  Unknown elements intentionally remain
    /// generic markup, so this is a semantic upgrade rather than an attempt
    /// to turn HTML into a lossy Djot-only parser.
    fn semanticKind(self: *Parser, name: []const u8, attrs: []const AST.KeyVal, children: *[]Node.Id) ParseError!Node.Kind {
        if (std.mem.eql(u8, name, "p")) return .para;
        if (std.mem.eql(u8, name, "h1")) return .{ .heading = .{ .level = 1 } };
        if (std.mem.eql(u8, name, "h2")) return .{ .heading = .{ .level = 2 } };
        if (std.mem.eql(u8, name, "h3")) return .{ .heading = .{ .level = 3 } };
        if (std.mem.eql(u8, name, "h4")) return .{ .heading = .{ .level = 4 } };
        if (std.mem.eql(u8, name, "h5")) return .{ .heading = .{ .level = 5 } };
        if (std.mem.eql(u8, name, "h6")) return .{ .heading = .{ .level = 6 } };
        if (std.mem.eql(u8, name, "hr")) return .thematic_break;
        if (std.mem.eql(u8, name, "br")) return .hard_break;
        if (std.mem.eql(u8, name, "blockquote")) {
            children.* = self.dropFormattingWhitespace(children.*);
            return .block_quote;
        }
        if (std.mem.eql(u8, name, "div")) {
            children.* = self.dropFormattingWhitespace(children.*);
            return .{ .container = .{ .name = "div", .form = .block_fenced } };
        }
        // These are structural containers with no Djot syntax of their own;
        // `section` renders its children directly in the Djot serializer.
        if (std.mem.eql(u8, name, "html") or std.mem.eql(u8, name, "body") or std.mem.eql(u8, name, "main") or std.mem.eql(u8, name, "section")) {
            children.* = self.dropFormattingWhitespace(children.*);
            return .section;
        }
        if (std.mem.eql(u8, name, "ul")) {
            children.* = self.dropFormattingWhitespace(children.*);
            return .{ .bullet_list = .{ .tight = self.listIsTight(children.*) } };
        }
        if (std.mem.eql(u8, name, "ol")) {
            children.* = self.dropFormattingWhitespace(children.*);
            const start = if (attrValue(attrs, "start")) |value| std.fmt.parseInt(u32, value, 10) catch null else null;
            return .{ .ordered_list = .{ .numbering = .decimal, .tight = self.listIsTight(children.*), .start = start } };
        }
        if (std.mem.eql(u8, name, "li")) {
            children.* = self.dropFormattingWhitespace(children.*);
            try self.wrapListItemInParagraph(children);
            return .list_item;
        }
        if (std.mem.eql(u8, name, "table")) {
            children.* = self.dropFormattingWhitespace(children.*);
            try self.flattenRowGroups(children);
            return .table;
        }
        if (std.mem.eql(u8, name, "caption")) {
            children.* = self.dropFormattingWhitespace(children.*);
            return .caption;
        }
        if (std.mem.eql(u8, name, "tr")) {
            children.* = self.dropFormattingWhitespace(children.*);
            // The shared model carries `head` on the row as well as its cells;
            // in HTML the row has no marker of its own, so it follows from the
            // cells being `<th>`.
            return .{ .row = .{ .head = self.rowIsHead(children.*) } };
        }
        if (std.mem.eql(u8, name, "th") or std.mem.eql(u8, name, "td")) {
            children.* = self.dropFormattingWhitespace(children.*);
            return .{ .cell = .{
                .head = std.mem.eql(u8, name, "th"),
                .alignment = cellAlignment(attrs),
                .colspan = cellExtent(attrs, "colspan"),
                .rowspan = cellExtent(attrs, "rowspan"),
            } };
        }
        if (std.mem.eql(u8, name, "em") or std.mem.eql(u8, name, "i")) return .{ .inline_mark = .emph };
        if (std.mem.eql(u8, name, "strong") or std.mem.eql(u8, name, "b")) return .{ .inline_mark = .strong };
        if (std.mem.eql(u8, name, "mark")) return .{ .inline_mark = .mark };
        if (std.mem.eql(u8, name, "ins")) return .{ .inline_mark = .insert };
        if (std.mem.eql(u8, name, "del") or std.mem.eql(u8, name, "s")) return .{ .inline_mark = .delete };
        if (std.mem.eql(u8, name, "sup")) return .{ .inline_mark = .superscript };
        if (std.mem.eql(u8, name, "sub")) return .{ .inline_mark = .subscript };
        if (std.mem.eql(u8, name, "span")) return .{ .container = .{ .name = "span", .form = .inline_text } };
        if (std.mem.eql(u8, name, "a")) {
            if (attrValue(attrs, "href")) |destination|
                return .{ .link = .{ .destination = destination, .reference = null } };
        }
        if (std.mem.eql(u8, name, "img")) {
            if (attrValue(attrs, "src")) |destination| {
                // The shared `image` model carries alt text as child content,
                // not as an attribute; give the void node a `str` child so the
                // serializer reproduces `alt=`. The `src`/`alt` attributes are
                // still preserved on the node — the serializer dedups them
                // against the synthesized `src`/`alt` so neither doubles up.
                if (attrValue(attrs, "alt")) |alt| {
                    const child = try self.builder.addLeaf(.{ .str = alt });
                    children.* = try self.allocator.dupe(Node.Id, &.{child});
                }
                return .{ .image = .{ .destination = destination, .reference = null } };
            }
        }
        // Both of the next two mappings ABSORB their child into an opaque text
        // payload, so the child has to be dropped: `verbatim` and `code_block`
        // are `.text` in `Kind.contentModel`, which means the bytes and no
        // children. Left unreferenced rather than deleted, exactly as
        // `dropFormattingWhitespace` and `flattenRowGroups` leave theirs —
        // `ast/compact.zig` collects them at the end of the parse.
        if (std.mem.eql(u8, name, "code") and children.*.len == 1) {
            switch (self.builder.nodes.items[children.*[0]].kind) {
                .str => |text| {
                    children.* = &.{};
                    return .{ .text_leaf = .{ .kind = .verbatim, .text = text } };
                },
                else => {},
            }
        }
        if (std.mem.eql(u8, name, "pre") and children.*.len == 1) {
            const child = children.*[0];
            switch (self.builder.nodes.items[child].kind) {
                .text_leaf => |l| if (l.kind == .verbatim) {
                    const class = self.builderAttrs(child).get("class") orelse "";
                    const lang = languageFromClass(class);
                    children.* = &.{};
                    return .{ .code_block = .{ .lang = lang, .text = l.text } };
                },
                else => {},
            }
        }
        return .{ .container = .{ .name = name } };
    }

    /// `<thead>`/`<tbody>`/`<tfoot>` have no counterpart in the shared table
    /// model, which is `table -> caption?, row*` — and Twig's own Markdown
    /// renderer emits them, so a table that went out through HTML has to come
    /// back through here. Splice each group's rows into the table and drop the
    /// wrapper, which is left unreferenced exactly as dropped whitespace is.
    fn flattenRowGroups(self: *Parser, children: *[]Node.Id) ParseError!void {
        var found = false;
        for (children.*) |id| {
            if (self.isRowGroup(id)) {
                found = true;
                break;
            }
        }
        if (!found) return;
        self.row_scratch.clearRetainingCapacity();
        for (children.*) |id| {
            if (!self.isRowGroup(id)) {
                try self.row_scratch.append(self.allocator, id);
                continue;
            }
            var child = self.builder.nodes.items[id].first_child;
            while (child) |cid| : (child = self.builder.nodes.items[cid].next_sibling)
                try self.row_scratch.append(self.allocator, cid);
        }
        // The wrapper is a generic element, so the layout whitespace INSIDE it
        // was never dropped — it arrives here still interleaved with the rows,
        // where each blank text node would serialize as an empty `|` row.
        children.* = self.dropFormattingWhitespace(self.row_scratch.items);
    }

    fn isRowGroup(self: *const Parser, id: Node.Id) bool {
        return switch (self.builder.nodes.items[id].kind) {
            .container => |c| std.mem.eql(u8, c.name, "thead") or
                std.mem.eql(u8, c.name, "tbody") or
                std.mem.eql(u8, c.name, "tfoot"),
            else => false,
        };
    }

    fn rowIsHead(self: *const Parser, children: []const Node.Id) bool {
        var saw_cell = false;
        for (children) |id| switch (self.builder.nodes.items[id].kind) {
            .cell => |c| {
                if (!c.head) return false;
                saw_cell = true;
            },
            else => {},
        };
        return saw_cell;
    }

    /// Twig's HTML renderer spells alignment `style="text-align: left;"`, which
    /// is the form that has to round-trip; `align="left"` is read too, since
    /// it's what hand-written and legacy HTML uses.
    fn cellAlignment(attrs: []const AST.KeyVal) AST.Alignment {
        if (attrValue(attrs, "style")) |style| {
            if (std.mem.indexOf(u8, style, "text-align")) |at| {
                var rest = style[at + "text-align".len ..];
                rest = std.mem.trimStart(u8, rest, " \t");
                if (rest.len > 0 and rest[0] == ':') {
                    rest = std.mem.trimStart(u8, rest[1..], " \t");
                    const end = std.mem.indexOfAny(u8, rest, "; \t") orelse rest.len;
                    if (alignmentFromName(rest[0..end])) |alignment| return alignment;
                }
            }
        }
        if (attrValue(attrs, "align")) |value| {
            if (alignmentFromName(value)) |alignment| return alignment;
        }
        return .default;
    }

    /// A cell's `colspan`/`rowspan` as the shared model's grid extent: at least
    /// 1, and 1 for anything that isn't a positive integer. `rowspan="0"` — the
    /// one HTML spelling that means something other than a count ("to the end of
    /// the row group") — normalizes to 1 here and survives on the node's own
    /// attributes instead; see `AST.Kind.Cell`.
    fn cellExtent(attrs: []const AST.KeyVal, key: []const u8) u32 {
        const value = attrValue(attrs, key) orelse return 1;
        const n = std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t\r\n"), 10) catch return 1;
        return if (n == 0) 1 else n;
    }

    fn alignmentFromName(name: []const u8) ?AST.Alignment {
        if (std.ascii.eqlIgnoreCase(name, "left")) return .left;
        if (std.ascii.eqlIgnoreCase(name, "right")) return .right;
        if (std.ascii.eqlIgnoreCase(name, "center")) return .center;
        return null;
    }

    fn attrValue(attrs: []const AST.KeyVal, key: []const u8) ?[]const u8 {
        for (attrs) |attr| if (std.mem.eql(u8, attr.key, key)) return attr.value;
        return null;
    }

    fn builderAttrs(self: *const Parser, id: Node.Id) AST.Attrs {
        const attr_id = self.builder.nodes.items[id].attrs orelse return .{};
        return self.builder.attrs.items[attr_id];
    }

    fn languageFromClass(class: []const u8) ?[]const u8 {
        var classes = std.mem.tokenizeScalar(u8, class, ' ');
        while (classes.next()) |item| {
            if (std.mem.startsWith(u8, item, "language-") and item.len > "language-".len)
                return item["language-".len..];
        }
        return null;
    }

    fn isFormattingWhitespace(self: *const Parser, id: Node.Id) bool {
        return switch (self.builder.nodes.items[id].kind) {
            .str => |text| std.mem.trim(u8, text, " \t\r\n").len == 0,
            else => false,
        };
    }

    /// The shared HTML printer deliberately puts newlines between block tags.
    /// Those are layout, not document text, so do not turn them into blank
    /// Djot paragraphs when parsing a printer-produced document.
    fn dropFormattingWhitespace(self: *Parser, children: []Node.Id) []Node.Id {
        var out: usize = 0;
        for (children) |id| {
            if (self.isFormattingWhitespace(id)) continue;
            children[out] = id;
            out += 1;
        }
        const kept = children[0..out];
        // A text run adjacent to a block boundary — the container edge, or a
        // block-level sibling — carries only layout whitespace at that side.
        // The serializer re-emits that whitespace as a structural newline, so
        // leaving it in makes blank lines accumulate without bound on each
        // parse→serialize round-trip. Trim those block-facing edges (never the
        // side facing inline content, where whitespace is significant).
        for (kept, 0..) |id, i| {
            if (self.builder.nodes.items[id].kind != .str) continue;
            if (i == 0 or self.isBlockKind(kept[i - 1])) self.trimTextEdge(id, .leading);
            if (i + 1 == kept.len or self.isBlockKind(kept[i + 1])) self.trimTextEdge(id, .trailing);
        }
        return kept;
    }

    fn isBlockKind(self: *const Parser, id: Node.Id) bool {
        return switch (self.builder.nodes.items[id].kind) {
            .para, .heading, .thematic_break, .section, .container, .code_block, .block_quote, .bullet_list, .ordered_list, .task_list, .definition_list, .table, .list_item, .task_list_item, .definition_list_item, .term, .definition => true,
            else => false,
        };
    }

    fn trimTextEdge(self: *Parser, id: Node.Id, side: enum { leading, trailing }) void {
        const node = &self.builder.nodes.items[id];
        const text = switch (node.kind) {
            .str => |t| t,
            else => return,
        };
        const ws = " \t\r\n\x0c";
        const trimmed = switch (side) {
            .leading => std.mem.trimStart(u8, text, ws),
            .trailing => std.mem.trimEnd(u8, text, ws),
        };
        if (trimmed.len == text.len) return;
        // Whitespace is never part of a character reference, so the trimmed
        // byte count maps 1:1 onto source bytes at this edge — the span (which
        // indexes the original source) stays accurate.
        const removed = text.len - trimmed.len;
        node.kind = .{ .str = trimmed };
        switch (side) {
            .leading => self.builder.spans.items[id].start += removed,
            .trailing => self.builder.spans.items[id].end -= removed,
        }
    }

    /// Wrap each maximal run of inline content in a list item into a paragraph,
    /// leaving block-level children (block quotes, nested lists, headings, …)
    /// as siblings. Wrapping a block inside a `<p>` would be invalid markup and
    /// would dedent it during serialization. Rewrites `children` in place: the
    /// output count never exceeds the input, and each write lands at or before
    /// the run the builder already consumed, so it never clobbers unread ids.
    fn wrapListItemInParagraph(self: *Parser, children: *[]Node.Id) ParseError!void {
        const items = children.*;
        var out: usize = 0;
        var i: usize = 0;
        while (i < items.len) {
            if (self.isBlockKind(items[i])) {
                items[out] = items[i];
                out += 1;
                i += 1;
                continue;
            }
            const run_start = i;
            while (i < items.len and !self.isBlockKind(items[i])) i += 1;
            const run = items[run_start..i];
            const span_start = self.builder.spans.items[run[0]].start;
            const span_end = self.builder.spans.items[run[run.len - 1]].end;
            const para = try self.builder.addContainer(.para, run);
            self.builder.setSpan(para, Span.init(span_start, span_end));
            self.builder.setContentSpan(para, Span.init(span_start, span_end));
            items[out] = para;
            out += 1;
        }
        children.* = items[0..out];
    }

    fn listIsTight(self: *const Parser, children: []const Node.Id) bool {
        for (children) |item| {
            if (self.builder.nodes.items[item].kind != .list_item) continue;
            const first = self.builder.nodes.items[item].first_child orelse continue;
            const para = self.builder.nodes.items[first];
            const para_start = self.builder.spans.items[first].start;
            if (para.kind != .para or para_start >= self.source.len or !std.mem.startsWith(u8, self.source[para_start..], "<p")) return true;
        }
        return false;
    }

    fn rawTextEnd(self: *Parser, name: []const u8) usize {
        if (std.mem.eql(u8, name, "plaintext")) return self.source.len;
        var i = self.pos;
        while (i + 2 < self.source.len) : (i += 1) {
            if (self.source[i] != '<' or self.source[i + 1] != '/') continue;
            var j = i + 2;
            while (j < self.source.len and isNameByte(self.source[j])) j += 1;
            if (j > i + 2 and std.ascii.eqlIgnoreCase(self.source[i + 2 .. j], name) and
                (j == self.source.len or isSpace(self.source[j]) or self.source[j] == '>')) return i;
        }
        return self.source.len;
    }

    fn parseAttributes(self: *Parser) ParseError![]AST.KeyVal {
        var attrs = std.ArrayList(AST.KeyVal).empty;
        errdefer {
            for (attrs.items) |kv| {
                self.allocator.free(kv.key);
                if (kv.value) |value| self.allocator.free(value);
            }
            attrs.deinit(self.allocator);
        }
        while (self.pos < self.source.len) {
            self.skipSpace();
            if (self.pos >= self.source.len or self.source[self.pos] == '>' or self.source[self.pos] == '/') break;
            if (!isNameByte(self.source[self.pos])) {
                self.pos += 1;
                continue;
            }
            const key = try self.readNameLower();
            var value: ?[]u8 = null;
            self.skipSpace();
            if (self.pos < self.source.len and self.source[self.pos] == '=') {
                self.pos += 1;
                self.skipSpace();
                value = self.readAttributeValue() catch |err| {
                    self.allocator.free(key);
                    return err;
                };
            }
            attrs.append(self.allocator, .{ .key = key, .value = value }) catch |err| {
                self.allocator.free(key);
                if (value) |v| self.allocator.free(v);
                return err;
            };
        }
        return attrs.toOwnedSlice(self.allocator);
    }

    fn freeAttrs(self: *Parser, attrs: []const AST.KeyVal) void {
        for (attrs) |kv| {
            self.allocator.free(kv.key);
            if (kv.value) |value| self.allocator.free(value);
        }
        self.allocator.free(attrs);
    }

    fn readAttributeValue(self: *Parser) ParseError![]u8 {
        const start = self.pos;
        var end = self.pos;
        if (self.pos < self.source.len and (self.source[self.pos] == '\'' or self.source[self.pos] == '"')) {
            const quote = self.source[self.pos];
            self.pos += 1;
            const quoted_start = self.pos;
            while (self.pos < self.source.len and self.source[self.pos] != quote) self.pos += 1;
            end = self.pos;
            if (self.pos < self.source.len) self.pos += 1;
            return self.decodeText(self.source[quoted_start..end]);
        }
        while (self.pos < self.source.len and !isSpace(self.source[self.pos]) and self.source[self.pos] != '>' and self.source[self.pos] != '/') self.pos += 1;
        end = self.pos;
        return self.decodeText(self.source[start..end]);
    }

    fn parseTextUntil(self: *Parser, limit: usize, decode_entities: bool) ParseError!?Node.Id {
        const start = self.pos;
        while (self.pos < limit and self.source[self.pos] != '<') self.pos += 1;
        return self.parseTextRange(start, self.pos, decode_entities);
    }

    fn parseTextRange(self: *Parser, start: usize, end: usize, decode_entities: bool) ParseError!?Node.Id {
        if (end == start) return null;
        const text = if (decode_entities) try self.decodeText(self.source[start..end]) else try self.allocator.dupe(u8, self.source[start..end]);
        defer self.allocator.free(text);
        const id = try self.builder.addLeaf(.{ .str = text });
        self.builder.setSpan(id, Span.init(start, end));
        return id;
    }

    fn decodeText(self: *Parser, text: []const u8) ParseError![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] != '&') {
                try out.append(self.allocator, text[i]);
                i += 1;
                continue;
            }
            const semi = std.mem.indexOfScalarPos(u8, text, i + 1, ';') orelse {
                try out.append(self.allocator, '&');
                i += 1;
                continue;
            };
            const body = text[i + 1 .. semi];
            if (try appendEntity(&out, self.allocator, body)) {
                i = semi + 1;
            } else {
                try out.appendSlice(self.allocator, text[i .. semi + 1]);
                i = semi + 1;
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn parseComment(self: *Parser) ParseError!Node.Id {
        const start = self.pos;
        self.pos += 4;
        const content_start = self.pos;
        const end = std.mem.indexOfPos(u8, self.source, self.pos, "-->") orelse self.source.len;
        self.pos = if (end < self.source.len) end + 3 else end;
        const id = try self.builder.addLeaf(.{ .markup_leaf = .{ .kind = .comment, .text = self.source[content_start..end] } });
        self.builder.setSpan(id, Span.init(start, self.pos));
        self.builder.setContentSpan(id, Span.init(content_start, end));
        return id;
    }

    fn parseBogusComment(self: *Parser) ParseError!Node.Id {
        const start = self.pos;
        self.pos += 2;
        const content_start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '>') self.pos += 1;
        const end = self.pos;
        if (self.pos < self.source.len) self.pos += 1;
        const id = try self.builder.addLeaf(.{ .markup_leaf = .{ .kind = .comment, .text = self.source[content_start..end] } });
        self.builder.setSpan(id, Span.init(start, self.pos));
        self.builder.setContentSpan(id, Span.init(content_start, end));
        return id;
    }

    fn parseDoctype(self: *Parser) ParseError!Node.Id {
        const start = self.pos;
        self.pos += "<!doctype".len;
        const content_start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '>') self.pos += 1;
        const end = self.pos;
        if (self.pos < self.source.len) self.pos += 1;
        const id = try self.builder.addLeaf(.{ .markup_leaf = .{ .kind = .doctype, .text = self.source[content_start..end] } });
        self.builder.setSpan(id, Span.init(start, self.pos));
        self.builder.setContentSpan(id, Span.init(content_start, end));
        return id;
    }

    fn parseProcessingInstruction(self: *Parser) ParseError!Node.Id {
        const start = self.pos;
        self.pos += 2;
        const target_start = self.pos;
        while (self.pos < self.source.len and isNameByte(self.source[self.pos])) self.pos += 1;
        const target = self.source[target_start..self.pos];
        self.skipSpace();
        const data_start = self.pos;
        const end = std.mem.indexOfPos(u8, self.source, self.pos, "?>") orelse self.source.len;
        self.pos = if (end < self.source.len) end + 2 else end;
        const id = try self.builder.addLeaf(.{ .processing_instruction = .{ .target = target, .data = self.source[data_start..end] } });
        self.builder.setSpan(id, Span.init(start, self.pos));
        // `content_span` stays `null`: a PI's payload is split across two
        // fields (target + data), so there is no single unambiguous interior
        // between `<?` and `?>` to point at (see the XML parser's PI note).
        return id;
    }
};

fn appendEntity(out: *std.ArrayList(u8), allocator: Allocator, body: []const u8) Allocator.Error!bool {
    if (body.len > 1 and body[0] == '#') {
        const cp: u21 = if (body.len > 2 and (body[1] == 'x' or body[1] == 'X'))
            std.fmt.parseInt(u21, body[2..], 16) catch return false
        else
            std.fmt.parseInt(u21, body[1..], 10) catch return false;
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &bytes) catch return false;
        try out.appendSlice(allocator, bytes[0..len]);
        return true;
    }
    const replacement: ?[]const u8 = if (std.mem.eql(u8, body, "amp")) "&" else if (std.mem.eql(u8, body, "lt")) "<" else if (std.mem.eql(u8, body, "gt")) ">" else if (std.mem.eql(u8, body, "quot")) "\"" else if (std.mem.eql(u8, body, "apos")) "'" else if (std.mem.eql(u8, body, "nbsp")) "\xc2\xa0" else if (std.mem.eql(u8, body, "copy")) "\xc2\xa9" else if (std.mem.eql(u8, body, "reg")) "\xc2\xae" else if (std.mem.eql(u8, body, "hellip")) "\xe2\x80\xa6" else if (std.mem.eql(u8, body, "ndash")) "\xe2\x80\x93" else if (std.mem.eql(u8, body, "mdash")) "\xe2\x80\x94" else if (std.mem.eql(u8, body, "lsquo")) "\xe2\x80\x98" else if (std.mem.eql(u8, body, "rsquo")) "\xe2\x80\x99" else if (std.mem.eql(u8, body, "ldquo")) "\xe2\x80\x9c" else if (std.mem.eql(u8, body, "rdquo")) "\xe2\x80\x9d" else null;
    if (replacement) |value| {
        try out.appendSlice(allocator, value);
        return true;
    }
    return false;
}

const testing = std.testing;

test "HTML parser maps block markup and decodes character references" {
    var parser = Parser.init(testing.allocator, "<!doctype html><DIV class=x disabled>Hi &amp; &#x1f642;</DIV>");
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();
    const doctype = ast.ast.nodes[ast.ast.root].first_child.?;
    const div = ast.ast.nodes[doctype].next_sibling.?;
    const text = ast.ast.nodes[div].first_child.?;
    try testing.expectEqualStrings(" html", ast.ast.nodes[doctype].kind.markup_leaf.text);
    try testing.expectEqualStrings("div", ast.ast.nodes[div].kind.container.name);
    try testing.expectEqualStrings("x", ast.ast.attrsOf(div).get("class").?);
    try testing.expect(ast.ast.attrsOf(div).find("disabled").?.value == null);
    try testing.expectEqualStrings("Hi & 🙂", ast.ast.nodes[text].kind.str);
}

test "HTML parser maps tables to the shared table vocabulary" {
    var parser = Parser.init(testing.allocator, "<table><caption>C</caption><tr><th>a</th></tr><tr><td>1</td></tr></table>");
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();
    const table = ast.ast.nodes[ast.ast.root].first_child.?;
    try testing.expect(ast.ast.nodes[table].kind == .table);
    const caption = ast.ast.nodes[table].first_child.?;
    try testing.expect(ast.ast.nodes[caption].kind == .caption);
    const head_row = ast.ast.nodes[caption].next_sibling.?;
    const body_row = ast.ast.nodes[head_row].next_sibling.?;
    // A row has no header marker of its own in HTML; `head` follows from `<th>`.
    try testing.expect(ast.ast.nodes[head_row].kind.row.head);
    try testing.expect(!ast.ast.nodes[body_row].kind.row.head);
    try testing.expect(ast.ast.nodes[ast.ast.nodes[head_row].first_child.?].kind.cell.head);
    try testing.expect(!ast.ast.nodes[ast.ast.nodes[body_row].first_child.?].kind.cell.head);
}

test "HTML parser splices row groups into the table, whitespace and all" {
    // Twig's own Markdown renderer emits `<thead>`/`<tbody>`, so this is the
    // shape a table takes on the way back in. The shared model has no row
    // group, and the whitespace inside a wrapper was never dropped — left in,
    // each blank text node serializes as an empty `|` row.
    const source =
        \\<table>
        \\<thead>
        \\<tr>
        \\<th>a</th>
        \\</tr>
        \\</thead>
        \\<tbody>
        \\<tr>
        \\<td>1</td>
        \\</tr>
        \\</tbody>
        \\</table>
    ;
    var parser = Parser.init(testing.allocator, source);
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();
    const table = ast.ast.nodes[ast.ast.root].first_child.?;
    try testing.expect(ast.ast.nodes[table].kind == .table);
    var rows: usize = 0;
    var child = ast.ast.nodes[table].first_child;
    while (child) |id| : (child = ast.ast.nodes[id].next_sibling) {
        try testing.expect(ast.ast.nodes[id].kind == .row);
        rows += 1;
    }
    try testing.expectEqual(@as(usize, 2), rows);
}

test "HTML parser reads cell alignment from style and from the legacy attribute" {
    var parser = Parser.init(testing.allocator, "<table><tr><td style=\"text-align: right;\">a</td><td align=\"CENTER\">b</td><td style=\"color: red\">c</td></tr></table>");
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();
    const row = ast.ast.nodes[ast.ast.nodes[ast.ast.root].first_child.?].first_child.?;
    const first = ast.ast.nodes[row].first_child.?;
    const second = ast.ast.nodes[first].next_sibling.?;
    const third = ast.ast.nodes[second].next_sibling.?;
    // `style` is what Twig's printer emits, so it's the one that must survive;
    // `align` is read for hand-written HTML, case-insensitively.
    try testing.expectEqual(AST.Alignment.right, ast.ast.nodes[first].kind.cell.alignment);
    try testing.expectEqual(AST.Alignment.center, ast.ast.nodes[second].kind.cell.alignment);
    // An unrelated style declaration is not an alignment.
    try testing.expectEqual(AST.Alignment.default, ast.ast.nodes[third].kind.cell.alignment);
}

test "HTML parser reads cell colspan and rowspan, normalizing the non-counts to 1" {
    var parser = Parser.init(testing.allocator, "<table><tr>" ++
        "<td colspan=\"2\" rowspan=\"3\">a</td>" ++
        "<td>b</td>" ++
        "<td rowspan=\"0\">c</td>" ++
        "<td colspan=\"nope\">d</td>" ++
        "</tr></table>");
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();
    const row = ast.ast.nodes[ast.ast.nodes[ast.ast.root].first_child.?].first_child.?;
    const a = ast.ast.nodes[row].first_child.?;
    const b = ast.ast.nodes[a].next_sibling.?;
    const c = ast.ast.nodes[b].next_sibling.?;
    const d = ast.ast.nodes[c].next_sibling.?;
    try testing.expectEqual(@as(u32, 2), ast.ast.nodes[a].kind.cell.colspan);
    try testing.expectEqual(@as(u32, 3), ast.ast.nodes[a].kind.cell.rowspan);
    // A cell with no attribute is the one-square default.
    try testing.expectEqual(@as(u32, 1), ast.ast.nodes[b].kind.cell.colspan);
    try testing.expectEqual(@as(u32, 1), ast.ast.nodes[b].kind.cell.rowspan);
    // `rowspan="0"` means "to the end of the row group", not a count — the
    // shared model says 1 and the raw attribute carries the real spelling.
    try testing.expectEqual(@as(u32, 1), ast.ast.nodes[c].kind.cell.rowspan);
    try testing.expectEqualStrings("0", ast.ast.attrsOf(c).get("rowspan").?);
    // Neither is a garbage value.
    try testing.expectEqual(@as(u32, 1), ast.ast.nodes[d].kind.cell.colspan);
}

test "HTML parser closes li and p implicitly and keeps script raw" {
    var parser = Parser.init(testing.allocator, "<ul><li>one<li>two</ul><p>a<div>b</div><script>a < b &amp;</script>");
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();
    const ul = ast.ast.nodes[ast.ast.root].first_child.?;
    const first_li = ast.ast.nodes[ul].first_child.?;
    const second_li = ast.ast.nodes[first_li].next_sibling.?;
    const p = ast.ast.nodes[ul].next_sibling.?;
    const div = ast.ast.nodes[p].next_sibling.?;
    const script = ast.ast.nodes[div].next_sibling.?;
    try testing.expect(ast.ast.nodes[first_li].kind == .list_item);
    try testing.expect(ast.ast.nodes[second_li].kind == .list_item);
    try testing.expect(ast.ast.nodes[p].kind == .para);
    try testing.expectEqualStrings("div", ast.ast.nodes[div].kind.container.name);
    const script_text = ast.ast.nodes[script].first_child.?;
    try testing.expectEqualStrings("a < b &amp;", ast.ast.nodes[script_text].kind.str);
}

test "HTML parser restores Twig printer semantics and ignores layout whitespace" {
    const source =
        \\<h1>Title</h1>
        \\<p>hello <a href="/u"><em>world</em></a></p>
        \\<ul>
        \\<li>
        \\<p>one</p>
        \\</li>
        \\<li>
        \\<p>two</p>
        \\</li>
        \\</ul>
        \\<pre><code class="language-zig">const x = 1;
        \\</code></pre>
    ;
    var parser = Parser.init(testing.allocator, source);
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();

    const heading = ast.ast.nodes[ast.ast.root].first_child.?;
    const para = ast.ast.nodes[heading].next_sibling.?;
    const list = ast.ast.nodes[para].next_sibling.?;
    const code = ast.ast.nodes[list].next_sibling.?;
    try testing.expectEqual(@as(u32, 1), ast.ast.nodes[heading].kind.heading.level);
    try testing.expect(ast.ast.nodes[para].kind == .para);
    const link = ast.ast.nodes[ast.ast.nodes[para].first_child.?].next_sibling.?;
    try testing.expectEqualStrings("/u", ast.ast.nodes[link].kind.link.destination.?);
    try testing.expect(!ast.ast.nodes[list].kind.bullet_list.tight);
    const item = ast.ast.nodes[list].first_child.?;
    try testing.expect(ast.ast.nodes[item].kind == .list_item);
    try testing.expect(ast.ast.nodes[ast.ast.nodes[item].first_child.?].kind == .para);
    try testing.expectEqualStrings("zig", ast.ast.nodes[code].kind.code_block.lang.?);
    try testing.expectEqualStrings("const x = 1;\n", ast.ast.nodes[code].kind.code_block.text);
}

test "HTML round-trip does not duplicate attributes promoted to semantic fields" {
    // A semantic upgrade (`a`->link, `img`->image, `ol`->ordered_list) pulls
    // `href`/`src`/`start` into a field *and* keeps the raw attribute; the
    // serializer must emit each key exactly once. `<img>`'s alt text becomes
    // node content so it survives the void-element round-trip.
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "<a href=\"/x\" class=\"c\">hi</a>", .out = "<a href=\"/x\" class=\"c\">hi</a>" },
        .{ .in = "<img src=\"/p.png\" alt=\"pic\" class=\"t\">", .out = "<img alt=\"pic\" src=\"/p.png\" class=\"t\">" },
        .{ .in = "<ol start=\"3\"><li>x</ol>", .out = "<ol start=\"3\">\n<li>\nx\n</li>\n</ol>\n" },
    };
    for (cases) |c| {
        var parser = Parser.init(testing.allocator, c.in);
        defer parser.deinit();
        var ast = try parser.parse();
        defer ast.deinit();
        const html = try @import("serializer.zig").serializeAlloc(testing.allocator, &ast.ast, null);
        defer testing.allocator.free(html);
        try testing.expectEqualStrings(c.out, html);
    }
}

fn parseToHtml(source: []const u8) ![]u8 {
    var parser = Parser.init(testing.allocator, source);
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();
    return @import("serializer.zig").serializeAlloc(testing.allocator, &ast.ast, null);
}

test "cell spans survive parse->serialize, and rowspan=0 rides the raw attribute" {
    // A counted span goes out through the semantic field (and the duplicate raw
    // attribute is deduped away, so neither doubles up). `rowspan="0"` is HTML's
    // "to the end of the row group", not a count: it normalizes to an extent of
    // 1, the serializer synthesizes nothing for it, and the node's own attribute
    // is what reaches the output — see `AST.Kind.Cell`.
    const html = try parseToHtml("<table><tr>" ++
        "<td colspan=\"2\" rowspan=\"3\">a</td>" ++
        "<td rowspan=\"0\">b</td>" ++
        "</tr></table>");
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<table>\n<tr>\n" ++
        "<td colspan=\"2\" rowspan=\"3\">a</td>\n" ++
        "<td rowspan=\"0\">b</td>\n" ++
        "</tr>\n</table>\n", html);
}

test "HTML raw-text elements are serialized literally, not escaped" {
    // `<`/`&` inside script/style have no character-reference meaning: escaping
    // them would corrupt the JS/CSS and double-escape on every re-parse.
    const html = try parseToHtml("<script>if (a < b && c) x();</script><style>.a>.b{x:1}</style>");
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<script>if (a < b && c) x();</script><style>.a>.b{x:1}</style>", html);
}

test "HTML parse->serialize is a fixpoint (no whitespace accumulation)" {
    // The serializer inserts structural newlines between block tags. Re-parsing
    // its own output must not fold those into text and re-emit them, or blank
    // lines grow without bound across edit cycles.
    const sources = [_][]const u8{
        "<ul><li>one<li>two</ul>",
        "<blockquote><p>q</p></blockquote>",
        "<p>a<b>bold</b></p>trailing",
        "<ul><li>a<ul><li>b</li></ul></li></ul>",
        "<div>hello <em>there</em> world</div>",
    };
    for (sources) |src| {
        const pass1 = try parseToHtml(src);
        defer testing.allocator.free(pass1);
        const pass2 = try parseToHtml(pass1);
        defer testing.allocator.free(pass2);
        try testing.expectEqualStrings(pass1, pass2);
    }
}

test "HTML tight-list item text stays on the marker's line through djot/markdown" {
    // The shared printer emits a tight `<li>` as `<li>\ntext\n</li>`. If the
    // parser keeps that leading newline as item text, the djot/Markdown
    // serializer emits a bare `- \n  text` instead of `- text`. (Regression
    // for the html->djot / html->markdown list round-trip.)
    const tight_list_html = "<ul>\n<li>\none\n</li>\n<li>\ntwo\n</li>\n</ul>\n";
    var parser = Parser.init(testing.allocator, tight_list_html);
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();

    const djot = try @import("../djot/serializer.zig").serializeAstAlloc(testing.allocator, &ast.ast);
    defer testing.allocator.free(djot);
    try testing.expectEqualStrings("- one\n- two\n", djot);

    const md = try @import("../markdown/serializer.zig").serializeAstAlloc(testing.allocator, &ast.ast);
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- one\n- two\n", md);
}

test "HTML block-level child of a list item is not wrapped in a paragraph" {
    // `wrapListItemInParagraph` must group only inline runs; a `<blockquote>`
    // (or nested list) stays a sibling of the text paragraph, never a child of
    // it — a block inside a `<p>` is invalid and dedents on serialization.
    const html = "<ul><li>text<blockquote>quoted</blockquote></li></ul>";
    var parser = Parser.init(testing.allocator, html);
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();

    const list = ast.ast.nodes[ast.ast.root].first_child.?;
    const item = ast.ast.nodes[list].first_child.?;
    const para = ast.ast.nodes[item].first_child.?;
    try testing.expect(ast.ast.nodes[para].kind == .para);
    // The paragraph holds only the inline text, not the block quote.
    const para_child = ast.ast.nodes[para].first_child.?;
    try testing.expect(ast.ast.nodes[para_child].kind == .str);
    try testing.expect(ast.ast.nodes[para_child].next_sibling == null);
    // The block quote is the paragraph's sibling under the list item.
    const bq = ast.ast.nodes[para].next_sibling.?;
    try testing.expect(ast.ast.nodes[bq].kind == .block_quote);
}

test "HTML soft-wrapped list-item paragraph keeps continuation indent in djot/markdown" {
    // An HTML paragraph keeps its soft-wrapped lines as one `str` with embedded
    // newlines (unlike native Markdown's str/soft_break split). The djot/
    // Markdown serializer must re-indent the continuation line under the list
    // marker (`  two`), not dedent it to column 0. (Regression for the
    // html->djot / html->markdown wrapped-list-item round-trip.)
    const html = "<ul>\n<li>\n<p>one\ntwo</p>\n</li>\n</ul>\n";
    var parser = Parser.init(testing.allocator, html);
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();

    const djot = try @import("../djot/serializer.zig").serializeAstAlloc(testing.allocator, &ast.ast);
    defer testing.allocator.free(djot);
    try testing.expectEqualStrings("- one\n  two\n", djot);

    const md = try @import("../markdown/serializer.zig").serializeAstAlloc(testing.allocator, &ast.ast);
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- one\n  two\n", md);
}

test "HTML framed leaves carry an interior content_span" {
    const source = "<!doctype html><!-- hi --><!bogus><?pi go?>";
    var parser = Parser.init(testing.allocator, source);
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();

    const doctype = ast.ast.nodes[ast.ast.root].first_child orelse return error.TestExpectedNonNull;
    const comment = ast.ast.nodes[doctype].next_sibling orelse return error.TestExpectedNonNull;
    const bogus = ast.ast.nodes[comment].next_sibling orelse return error.TestExpectedNonNull;
    const pi = ast.ast.nodes[bogus].next_sibling orelse return error.TestExpectedNonNull;

    // doctype: interior between `<!doctype` and `>`.
    try testing.expect(ast.ast.nodes[doctype].kind == .markup_leaf and ast.ast.nodes[doctype].kind.markup_leaf.kind == .doctype);
    try testing.expectEqualStrings("<!doctype html>", Span.of(u8, ast.span(doctype), source));
    try testing.expectEqualStrings(" html", Span.of(u8, ast.contentSpan(doctype).?, source));

    // proper comment: interior between `<!--` and `-->`.
    try testing.expect(ast.ast.nodes[comment].kind == .markup_leaf and ast.ast.nodes[comment].kind.markup_leaf.kind == .comment);
    try testing.expectEqualStrings("<!-- hi -->", Span.of(u8, ast.span(comment), source));
    try testing.expectEqualStrings(" hi ", Span.of(u8, ast.contentSpan(comment).?, source));

    // bogus comment (`<!`…`>`) is emitted as a comment kind and also framed.
    try testing.expect(ast.ast.nodes[bogus].kind == .markup_leaf and ast.ast.nodes[bogus].kind.markup_leaf.kind == .comment);
    try testing.expectEqualStrings("<!bogus>", Span.of(u8, ast.span(bogus), source));
    try testing.expectEqualStrings("bogus", Span.of(u8, ast.contentSpan(bogus).?, source));

    // processing instruction: two payload fields, so content_span stays null.
    try testing.expect(ast.ast.nodes[pi].kind == .processing_instruction);
    try testing.expectEqual(@as(?Span, null), ast.contentSpan(pi));
}

test "HTML empty comment interior gets an empty content_span at the boundary" {
    const source = "<!---->";
    var parser = Parser.init(testing.allocator, source);
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();

    const comment = ast.ast.nodes[ast.ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.ast.nodes[comment].kind == .markup_leaf and ast.ast.nodes[comment].kind.markup_leaf.kind == .comment);
    const cs = ast.contentSpan(comment).?;
    try testing.expectEqual(@as(usize, 0), cs.len());
    try testing.expectEqual(ast.span(comment).start + "<!--".len, cs.start);
}
