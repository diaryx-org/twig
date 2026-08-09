//! Source -> `AST`, recursive-descent over well-formed XML 1.0 (no external
//! DTD processing — internal subsets are skipped over as opaque bytes, never
//! interpreted, so no custom entities beyond the five predefined ones plus
//! numeric character references).
//!
//! Unlike djot's block/inline scanners (`languages/djot/parser.zig`), XML's
//! nesting is fully explicit in the source (every container's extent is
//! delimited by a matching open/close tag pair, discovered as we go) so a
//! plain recursive descent whose call stack mirrors the element nesting can
//! hand children to `ast/builder.zig`'s batch `addContainer` the moment a
//! close tag is found, instead of managing a flat node array by hand the way
//! djot's parser must (see that file's module doc for why djot needs the
//! heavier approach). Each `parseX` function returns a finished `Node.Id`
//! with its children already attached.
//!
//! XML is strict: anything that doesn't fit the grammar is a hard parse
//! error (`Error`), not a best-effort recovery — paired with a `Diagnostic`
//! (a byte offset plus a static message) so callers can point an editor at
//! the exact failure. Construct a `Parser` directly (rather than only going
//! through `xml.zig`'s `parse` convenience wrapper) to read `.diagnostic`
//! after a failed `.parse()`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Span = @import("../../span.zig");

/// A parse failure's location and a human-readable (but not allocated —
/// always a string literal) explanation. `offset` is a byte index into the
/// source the failing `Parser` was constructed with.
pub const Diagnostic = struct { offset: usize, message: []const u8 };

/// `MalformedXml` is the catch-all for the many single-occurrence grammar
/// violations (bad name syntax, missing `=`, unquoted attribute value, ...)
/// that don't need their own variant because nothing downstream branches on
/// them specifically; the rest are pulled out because tests (and, later,
/// editor UI) plausibly want to distinguish them.
pub const Error = error{
    MalformedXml,
    MismatchedCloseTag,
    UnclosedElement,
    DuplicateAttribute,
    UnknownEntity,
    TextOutsideRoot,
    MultipleRoots,
    MissingRoot,
};

pub const ParseError = Error || Allocator.Error;

pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize = 0,
    builder: AST.Builder,
    /// Set the moment any `Error` is returned; stale (from a previous call)
    /// or `null` otherwise. Only meaningful after `.parse()` has returned an
    /// error.
    diagnostic: ?Diagnostic = null,

    pub fn init(allocator: Allocator, source: []const u8) Parser {
        return .{ .allocator = allocator, .source = source, .builder = AST.Builder.init(allocator) };
    }

    /// Safe to call unconditionally after `.parse()`, success or failure:
    /// `Builder.finish` (called on the success path) already empties the
    /// builder, so this is a no-op then, and on failure it releases whatever
    /// partial state the builder had accumulated.
    pub fn deinit(self: *Parser) void {
        self.builder.deinit();
    }

    /// Parse the whole document into a fresh, self-contained `AST` rooted at
    /// a `doc` node.
    pub fn parse(self: *Parser) ParseError!AST {
        const doc_id = try self.parseDocument();
        return self.builder.finish(doc_id);
    }

    // ── diagnostics ──────────────────────────────────────────────────────

    fn fail(self: *Parser, offset: usize, message: []const u8, e: Error) Error {
        self.diagnostic = .{ .offset = offset, .message = message };
        return e;
    }

    // ── low-level cursor helpers ─────────────────────────────────────────

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.source.len) self.source[self.pos] else null;
    }

    fn at(self: *Parser, needle: []const u8) bool {
        return self.pos + needle.len <= self.source.len and
            std.mem.eql(u8, self.source[self.pos..][0..needle.len], needle);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.source.len) : (self.pos += 1) {
            switch (self.source[self.pos]) {
                ' ', '\t', '\r', '\n' => {},
                else => break,
            }
        }
    }

    // Name production, simplified to ASCII letters/digits/`_`/`-`/`.`/`:`
    // plus "anything non-ASCII" (so UTF-8-encoded international names are
    // accepted without actually validating them against XML's full Unicode
    // `Name` grammar — a deliberate simplification; see xml.zig's module
    // doc for the full list of documented deviations).
    fn isNameStartByte(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == ':' or c >= 0x80;
    }

    fn isNameByte(c: u8) bool {
        return isNameStartByte(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
    }

    fn readName(self: *Parser) Error![]const u8 {
        const start = self.pos;
        if (self.pos >= self.source.len or !isNameStartByte(self.source[self.pos]))
            return self.fail(start, "expected a name", error.MalformedXml);
        self.pos += 1;
        while (self.pos < self.source.len and isNameByte(self.source[self.pos])) self.pos += 1;
        return self.source[start..self.pos];
    }

    // ── entity / character reference decoding ───────────────────────────

    /// `self.source[self.pos] == '&'` on entry. Decodes one entity or
    /// character reference and appends its replacement text to `out`,
    /// advancing `self.pos` past the trailing `;`. The five predefined
    /// entities and `&#NNNN;`/`&#xHHHH;` character references are supported;
    /// anything else is a parse error — there is no DTD, so no custom
    /// entities could ever be declared, and a bare unescaped `&` is already
    /// illegal XML.
    fn decodeEntityInto(self: *Parser, out: *std.ArrayList(u8)) ParseError!void {
        const amp_pos = self.pos;
        self.pos += 1;
        const semi = std.mem.findScalarPos(u8, self.source, self.pos, ';') orelse
            return self.fail(amp_pos, "'&' must be escaped as &amp; or begin a valid entity/character reference", error.MalformedXml);
        // A '<' before the ';' means this was never a real reference (most
        // likely a stray unescaped '&' followed by markup) rather than an
        // unterminated one — same diagnosis either way.
        if (std.mem.findScalarPos(u8, self.source, self.pos, '<')) |lt| {
            if (lt < semi) return self.fail(amp_pos, "'&' must be escaped as &amp;", error.MalformedXml);
        }
        const name = self.source[self.pos..semi];
        self.pos = semi + 1;

        if (name.len > 0 and name[0] == '#') {
            const cp: u21 = if (name.len > 1 and (name[1] == 'x' or name[1] == 'X'))
                std.fmt.parseInt(u21, name[2..], 16) catch
                    return self.fail(amp_pos, "invalid hexadecimal character reference", error.MalformedXml)
            else
                std.fmt.parseInt(u21, name[1..], 10) catch
                    return self.fail(amp_pos, "invalid decimal character reference", error.MalformedXml);
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch
                return self.fail(amp_pos, "character reference is not a valid Unicode scalar value", error.MalformedXml);
            try out.appendSlice(self.allocator, buf[0..n]);
            return;
        }

        const replacement: []const u8 = if (std.mem.eql(u8, name, "amp"))
            "&"
        else if (std.mem.eql(u8, name, "lt"))
            "<"
        else if (std.mem.eql(u8, name, "gt"))
            ">"
        else if (std.mem.eql(u8, name, "apos"))
            "'"
        else if (std.mem.eql(u8, name, "quot"))
            "\""
        else
            return self.fail(amp_pos, "unknown entity reference (no DTD, so no custom entities)", error.UnknownEntity);
        try out.appendSlice(self.allocator, replacement);
    }

    /// Read a run of character data up to (not including) the next `<` or
    /// EOF, decoding entities as it goes. Returns a freshly allocated,
    /// owned buffer the caller must free (typically right after handing it
    /// to `Builder.addLeaf`, which copies it again into the `AST`'s own
    /// storage).
    fn readText(self: *Parser) ParseError![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        while (self.pos < self.source.len and self.source[self.pos] != '<') {
            if (self.source[self.pos] == '&') {
                try self.decodeEntityInto(&out);
            } else {
                try out.append(self.allocator, self.source[self.pos]);
                self.pos += 1;
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Read a quoted (`"` or `'`) attribute value, decoding entities.
    /// A literal `<` inside the value is a well-formedness error even
    /// before the closing quote is reached (XML disallows it unconditionally).
    fn readAttrValue(self: *Parser) ParseError![]u8 {
        const quote = self.peek() orelse return self.fail(self.pos, "attribute value must be quoted", error.MalformedXml);
        if (quote != '"' and quote != '\'')
            return self.fail(self.pos, "attribute value must be quoted", error.MalformedXml);
        self.pos += 1;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        while (true) {
            const c = self.peek() orelse return self.fail(self.pos, "unterminated attribute value", error.MalformedXml);
            if (c == quote) {
                self.pos += 1;
                break;
            }
            if (c == '<') return self.fail(self.pos, "'<' is not allowed in an attribute value", error.MalformedXml);
            if (c == '&') {
                try self.decodeEntityInto(&out);
                continue;
            }
            try out.append(self.allocator, c);
            self.pos += 1;
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Parse `Name '=' AttValue` pairs (`S`-separated) up to (not including)
    /// the tag's closing `>` or `/>`. Returned entries' `.key`s borrow
    /// `self.source`; `.value`s are owned buffers the caller must free (see
    /// `parseElement`, the only caller).
    fn parseAttributes(self: *Parser) ParseError![]AST.KeyVal {
        var list = std.ArrayList(AST.KeyVal).empty;
        errdefer {
            for (list.items) |kv| self.allocator.free(kv.value.?);
            list.deinit(self.allocator);
        }
        while (true) {
            self.skipWhitespace();
            const c = self.peek() orelse return self.fail(self.pos, "tag was never closed", error.MalformedXml);
            if (c == '>' or c == '/') break;

            const name_start = self.pos;
            const name = try self.readName();
            for (list.items) |kv| {
                if (std.mem.eql(u8, kv.key, name))
                    return self.fail(name_start, "duplicate attribute", error.DuplicateAttribute);
            }
            self.skipWhitespace();
            if ((self.peek() orelse 0) != '=')
                return self.fail(self.pos, "expected '=' after attribute name", error.MalformedXml);
            self.pos += 1;
            self.skipWhitespace();
            const value = try self.readAttrValue();
            try list.append(self.allocator, .{ .key = name, .value = value });
        }
        return list.toOwnedSlice(self.allocator);
    }

    // ── generic-markup leaves ────────────────────────────────────────────

    fn parseComment(self: *Parser) ParseError!Node.Id {
        const start = self.pos;
        self.pos += "<!--".len;
        const text_start = self.pos;

        const dash = std.mem.findPos(u8, self.source, self.pos, "--") orelse
            return self.fail(start, "unterminated comment", error.MalformedXml);
        if (dash + 2 >= self.source.len)
            return self.fail(start, "unterminated comment", error.MalformedXml);
        if (self.source[dash + 2] != '>')
            // "--" not immediately followed by '>': a bare double hyphen,
            // which XML forbids inside comment content.
            return self.fail(dash, "'--' is not allowed inside a comment", error.MalformedXml);

        const text = self.source[text_start..dash];
        self.pos = dash + 3;
        const id = try self.builder.addLeaf(.{ .markup_leaf = .{ .kind = .comment, .text = text } });
        self.builder.setSpan(id, Span.init(start, self.pos));
        self.builder.setContentSpan(id, Span.init(text_start, dash));
        return id;
    }

    fn parseCdata(self: *Parser) ParseError!Node.Id {
        const start = self.pos;
        self.pos += "<![CDATA[".len;
        const text_start = self.pos;
        const end = std.mem.findPos(u8, self.source, self.pos, "]]>") orelse
            return self.fail(start, "unterminated CDATA section", error.MalformedXml);
        self.pos = end + 3;
        const id = try self.builder.addLeaf(.{ .markup_leaf = .{ .kind = .cdata, .text = self.source[text_start..end] } });
        self.builder.setSpan(id, Span.init(start, self.pos));
        self.builder.setContentSpan(id, Span.init(text_start, end));
        return id;
    }

    /// Also used for the XML declaration (`<?xml version="1.0"?>`): it isn't
    /// truly a processing instruction per the spec (it has its own grammar
    /// production, `XMLDecl`), but it round-trips perfectly as one — target
    /// `xml`, data the raw `version="1.0" ...` soup — so storing it that way
    /// keeps the AST's generic-markup vocabulary from growing an
    /// XML-declaration-only kind for no structural benefit.
    fn parseProcessingInstruction(self: *Parser) ParseError!Node.Id {
        const start = self.pos;
        self.pos += "<?".len;
        const target = try self.readName();
        self.skipWhitespace();
        const data_start = self.pos;
        const end = std.mem.findPos(u8, self.source, self.pos, "?>") orelse
            return self.fail(start, "unterminated processing instruction", error.MalformedXml);
        const data = self.source[data_start..end];
        self.pos = end + 2;
        const id = try self.builder.addLeaf(.{ .processing_instruction = .{ .target = target, .data = data } });
        self.builder.setSpan(id, Span.init(start, self.pos));
        // `content_span` stays `null`: unlike the opaque-text leaves
        // (comment/cdata/doctype), a PI's payload is split across two fields
        // (target + data), so there is no single unambiguous "interior". The
        // whole `<?`…`?>` interior would include the target (name-like, and
        // excluded from an element's content_span), while the data-only range
        // isn't "between the delimiters" — either choice misleads, so leave it.
        return id;
    }

    /// Payload is the raw bytes from just after `<!DOCTYPE` to just before
    /// the terminating `>`, verbatim (including whitespace) — "not parsed
    /// further" per `AST.MarkupLeafKind.doctype`'s doc comment, which also makes
    /// this the one generic-markup leaf whose serialization is a lossless
    /// byte round trip even with an internal subset. Quoted strings (public/
    /// system identifiers) and a bracketed internal subset may both contain
    /// `>`, so both are scanned over rather than naively stopping at the
    /// first `>`.
    fn parseDoctype(self: *Parser) ParseError!Node.Id {
        const start = self.pos;
        self.pos += "<!DOCTYPE".len;
        const guts_start = self.pos;
        var bracket_depth: usize = 0;
        while (true) {
            const c = self.peek() orelse return self.fail(start, "unterminated DOCTYPE declaration", error.MalformedXml);
            switch (c) {
                '"', '\'' => {
                    const quote = c;
                    self.pos += 1;
                    while (true) {
                        const q = self.peek() orelse return self.fail(start, "unterminated quoted string in DOCTYPE declaration", error.MalformedXml);
                        self.pos += 1;
                        if (q == quote) break;
                    }
                },
                '[' => {
                    bracket_depth += 1;
                    self.pos += 1;
                },
                ']' => {
                    if (bracket_depth > 0) bracket_depth -= 1;
                    self.pos += 1;
                },
                '>' => {
                    if (bracket_depth == 0) {
                        const guts_end = self.pos;
                        const guts = self.source[guts_start..self.pos];
                        self.pos += 1;
                        const id = try self.builder.addLeaf(.{ .markup_leaf = .{ .kind = .doctype, .text = guts } });
                        self.builder.setSpan(id, Span.init(start, self.pos));
                        self.builder.setContentSpan(id, Span.init(guts_start, guts_end));
                        return id;
                    }
                    self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
    }

    // ── elements ─────────────────────────────────────────────────────────

    /// `self.source[self.pos] == '<'`, followed by a name-start byte (i.e.
    /// this isn't any of the special `<!`/`<?`/`</` forms), on entry.
    /// Recurses into itself for nested elements — the call stack is the
    /// container stack, so there is no explicit one to maintain (see this
    /// file's module doc comment).
    fn parseElement(self: *Parser) ParseError!Node.Id {
        const start = self.pos;
        self.pos += 1;
        const name = try self.readName();

        const attrs = try self.parseAttributes();
        defer {
            for (attrs) |kv| self.allocator.free(kv.value.?);
            self.allocator.free(attrs);
        }

        const c = self.peek() orelse return self.fail(self.pos, "tag was never closed", error.MalformedXml);
        if (c == '/') {
            self.pos += 1;
            if ((self.peek() orelse 0) != '>')
                return self.fail(self.pos, "expected '>' to close a self-closing tag", error.MalformedXml);
            self.pos += 1;
            const id = try self.builder.addContainer(.{ .container = .{ .name = name } }, &.{});
            self.builder.setSpan(id, Span.init(start, self.pos));
            try self.builder.setAttrs(id, .{ .entries = attrs });
            // `content_span` stays `null`: that's the signal to the
            // serializer that this element was written self-closing (see
            // serializer.zig's module doc comment).
            return id;
        }
        std.debug.assert(c == '>');
        self.pos += 1;
        const content_start = self.pos;

        var children = std.ArrayList(Node.Id).empty;
        defer children.deinit(self.allocator);

        while (true) {
            if (self.pos >= self.source.len)
                return self.fail(start, "element was never closed", error.UnclosedElement);
            if (self.source[self.pos] == '<') {
                if (self.at("</")) break;
                if (self.at("<!--")) {
                    try children.append(self.allocator, try self.parseComment());
                } else if (self.at("<![CDATA[")) {
                    try children.append(self.allocator, try self.parseCdata());
                } else if (self.at("<?")) {
                    try children.append(self.allocator, try self.parseProcessingInstruction());
                } else if (self.at("<!")) {
                    return self.fail(self.pos, "declarations are not allowed inside element content", error.MalformedXml);
                } else {
                    try children.append(self.allocator, try self.parseElement());
                }
                continue;
            }
            const text_start = self.pos;
            const text = try self.readText();
            defer self.allocator.free(text);
            const id = try self.builder.addLeaf(.{ .str = text });
            self.builder.setSpan(id, Span.init(text_start, self.pos));
            try children.append(self.allocator, id);
        }

        const content_end = self.pos; // the '<' of "</"
        self.pos += "</".len;
        const close_name_start = self.pos;
        const close_name = try self.readName();
        if (!std.mem.eql(u8, close_name, name))
            return self.fail(close_name_start, "close tag name does not match the open tag", error.MismatchedCloseTag);
        self.skipWhitespace();
        if ((self.peek() orelse 0) != '>')
            return self.fail(self.pos, "expected '>' to close the end tag", error.MalformedXml);
        self.pos += 1;

        const id = try self.builder.addContainer(.{ .container = .{ .name = name } }, children.items);
        self.builder.setSpan(id, Span.init(start, self.pos));
        self.builder.setContentSpan(id, Span.init(content_start, content_end));
        try self.builder.setAttrs(id, .{ .entries = attrs });
        return id;
    }

    // ── document ─────────────────────────────────────────────────────────

    /// The root: prolog items (XML declaration, DOCTYPE, comments, PIs,
    /// whitespace), the single root element, and epilog items (comments,
    /// PIs, whitespace), all as direct children of a `doc` node, in source
    /// order. Whitespace between prolog/epilog items is kept as `str`
    /// children (not swallowed) for the same fidelity-over-tidiness reason
    /// in-element whitespace text is kept — see this module's doc comment.
    fn parseDocument(self: *Parser) ParseError!Node.Id {
        var children = std.ArrayList(Node.Id).empty;
        defer children.deinit(self.allocator);
        var root_seen = false;

        while (self.pos < self.source.len) {
            if (self.source[self.pos] == '<') {
                if (self.at("<!--")) {
                    try children.append(self.allocator, try self.parseComment());
                } else if (self.at("<![CDATA[")) {
                    return self.fail(self.pos, "a CDATA section is not allowed outside the root element", error.MalformedXml);
                } else if (self.at("<!DOCTYPE")) {
                    if (root_seen) return self.fail(self.pos, "DOCTYPE must precede the root element", error.MalformedXml);
                    try children.append(self.allocator, try self.parseDoctype());
                } else if (self.at("<?")) {
                    try children.append(self.allocator, try self.parseProcessingInstruction());
                } else if (self.at("</")) {
                    return self.fail(self.pos, "unexpected end tag (no matching open element)", error.MalformedXml);
                } else if (self.at("<!")) {
                    return self.fail(self.pos, "unrecognized declaration", error.MalformedXml);
                } else {
                    if (root_seen) return self.fail(self.pos, "a document can only have one root element", error.MultipleRoots);
                    try children.append(self.allocator, try self.parseElement());
                    root_seen = true;
                }
                continue;
            }
            const text_start = self.pos;
            const text = try self.readText();
            defer self.allocator.free(text);
            if (std.mem.trim(u8, text, " \t\r\n").len != 0)
                return self.fail(text_start, "text is not allowed outside the root element", error.TextOutsideRoot);
            if (text.len > 0) {
                const id = try self.builder.addLeaf(.{ .str = text });
                self.builder.setSpan(id, Span.init(text_start, self.pos));
                try children.append(self.allocator, id);
            }
        }
        if (!root_seen) return self.fail(self.source.len, "document has no root element", error.MissingRoot);

        const doc_id = try self.builder.addContainer(.doc, children.items);
        self.builder.setSpan(doc_id, Span.init(0, self.source.len));
        return doc_id;
    }
};

const testing = std.testing;

test "parses a minimal document" {
    var p = Parser.init(testing.allocator, "<a/>");
    defer p.deinit();
    var ast = try p.parse();
    defer ast.deinit();

    try testing.expect(ast.nodes[ast.root].kind == .doc);
    const root_el = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("a", ast.nodes[root_el].kind.container.name);
    try testing.expectEqual(@as(?Span, null), ast.nodes[root_el].content_span);
}

test "framed leaves carry an interior content_span" {
    const source = "<!DOCTYPE html><root><!-- hi --><![CDATA[x<y]]><?pi go?></root>";
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    var ast = try p.parse();
    defer ast.deinit();

    const doctype = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    const root_el = ast.nodes[doctype].next_sibling orelse return error.TestExpectedNonNull;
    const comment = ast.nodes[root_el].first_child orelse return error.TestExpectedNonNull;
    const cdata = ast.nodes[comment].next_sibling orelse return error.TestExpectedNonNull;
    const pi = ast.nodes[cdata].next_sibling orelse return error.TestExpectedNonNull;

    // doctype: span covers the delimiters, content_span is the interior.
    try testing.expect(ast.nodes[doctype].kind == .markup_leaf and ast.nodes[doctype].kind.markup_leaf.kind == .doctype);
    try testing.expectEqualStrings("<!DOCTYPE html>", Span.of(u8, ast.nodes[doctype].span, source));
    try testing.expectEqualStrings(" html", Span.of(u8, ast.nodes[doctype].content_span.?, source));

    // comment
    try testing.expect(ast.nodes[comment].kind == .markup_leaf and ast.nodes[comment].kind.markup_leaf.kind == .comment);
    try testing.expectEqualStrings("<!-- hi -->", Span.of(u8, ast.nodes[comment].span, source));
    try testing.expectEqualStrings(" hi ", Span.of(u8, ast.nodes[comment].content_span.?, source));

    // cdata
    try testing.expect(ast.nodes[cdata].kind == .markup_leaf and ast.nodes[cdata].kind.markup_leaf.kind == .cdata);
    try testing.expectEqualStrings("<![CDATA[x<y]]>", Span.of(u8, ast.nodes[cdata].span, source));
    try testing.expectEqualStrings("x<y", Span.of(u8, ast.nodes[cdata].content_span.?, source));

    // processing instruction: two payload fields, so content_span stays null.
    try testing.expect(ast.nodes[pi].kind == .processing_instruction);
    try testing.expectEqual(@as(?Span, null), ast.nodes[pi].content_span);
}

test "empty framed leaf interiors get an empty content_span at the boundary" {
    const source = "<root><!----><![CDATA[]]></root>";
    var p = Parser.init(testing.allocator, source);
    defer p.deinit();
    var ast = try p.parse();
    defer ast.deinit();

    const root_el = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    const comment = ast.nodes[root_el].first_child orelse return error.TestExpectedNonNull;
    const cdata = ast.nodes[comment].next_sibling orelse return error.TestExpectedNonNull;

    const comment_cs = ast.nodes[comment].content_span.?;
    try testing.expectEqual(@as(usize, 0), comment_cs.len());
    try testing.expectEqual(ast.nodes[comment].span.start + "<!--".len, comment_cs.start);

    const cdata_cs = ast.nodes[cdata].content_span.?;
    try testing.expectEqual(@as(usize, 0), cdata_cs.len());
    try testing.expectEqual(ast.nodes[cdata].span.start + "<![CDATA[".len, cdata_cs.start);
}

test "duplicate attribute is a parse error with a diagnostic" {
    var p = Parser.init(testing.allocator, "<a x=\"1\" x=\"2\"/>");
    defer p.deinit();
    try testing.expectError(error.DuplicateAttribute, p.parse());
    try testing.expectEqual(@as(usize, 9), p.diagnostic.?.offset);
}

test "unknown entity is a parse error pointing at the '&'" {
    var p = Parser.init(testing.allocator, "<a>&bogus;</a>");
    defer p.deinit();
    try testing.expectError(error.UnknownEntity, p.parse());
    try testing.expectEqual(@as(usize, 3), p.diagnostic.?.offset);
}

test "mismatched close tag" {
    var p = Parser.init(testing.allocator, "<a></b>");
    defer p.deinit();
    try testing.expectError(error.MismatchedCloseTag, p.parse());
}

test "unclosed element" {
    var p = Parser.init(testing.allocator, "<a><b></b>");
    defer p.deinit();
    try testing.expectError(error.UnclosedElement, p.parse());
}

test "text outside the root element" {
    var p = Parser.init(testing.allocator, "<a/>stray");
    defer p.deinit();
    try testing.expectError(error.TextOutsideRoot, p.parse());
}

test "multiple root elements" {
    var p = Parser.init(testing.allocator, "<a/><b/>");
    defer p.deinit();
    try testing.expectError(error.MultipleRoots, p.parse());
}

test "missing root element" {
    var p = Parser.init(testing.allocator, "<!-- just a comment -->");
    defer p.deinit();
    try testing.expectError(error.MissingRoot, p.parse());
}
