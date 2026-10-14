//! `twig-meta`: the config a document carries, read and edited through fig.
//!
//! twig finds a document's metadata — a `metadata` node, the frontmatter or
//! endmatter block the Markdown parser reads — and fig edits what is inside
//! it. The block's body is handed to `fig.Editor` as a config document of its
//! own, and whatever the editor leaves in its source is spliced back between
//! the block's fences. Every byte outside the body, the fences included, is
//! the host's as it was.
//!
//! This is what fig's `Embed` did before 6.0, which took embedding out of fig
//! (fig's `docs/migrating-to-6.md`, "Embedding has left fig"). twig's own
//! module stays fig-free: this one is built only with `-Dfig`, and imports
//! both. See `docs/proposals/fig-in-twig.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const twig = @import("twig");
const fig = @import("fig");

pub const Settings = @import("settings.zig");

const Span = twig.Span;
const NodeId = twig.AST.Node.Id;

/// Which of a document's metadata blocks: the one it opens with, or the
/// trailing one.
pub const Where = enum { front, end };

/// A located metadata block: where its fences and body sit in the host.
pub const Block = struct {
    node: NodeId,
    where: Where,
    /// The language tag as written on the fence (`yaml` for a bare `---`).
    lang: []const u8,
    /// The whole block, both fence lines included.
    span: Span,
    /// The bytes between the fences: every body line, each with its line
    /// ending. Empty, at the start of the closing fence, for a block with no
    /// body. This is what fig edits, and where its result goes back.
    body: Span,
};

/// The document's metadata block at `where`, or null when it has none.
/// `doc` is a parsed document over `host`; only Markdown's parser produces
/// `metadata` nodes today.
pub fn find(doc: *const twig.Document, host: []const u8, where: Where) ?Block {
    const root = doc.ast.root;
    const first = doc.ast.nodes[root].first_child orelse return null;
    const id = switch (where) {
        .front => first,
        .end => blk: {
            var last = first;
            while (doc.ast.nodes[last].next_sibling) |n| last = n;
            break :blk last;
        },
    };
    const meta = switch (doc.ast.nodes[id].kind) {
        .metadata => |m| m,
        else => return null,
    };
    const span = doc.span(id);
    // Frontmatter is the document's first block and endmatter its last; a
    // document holding only one block of metadata has it as both, and it is
    // the one at the position the source puts it.
    const leads = span.start == 0;
    if (leads != (where == .front)) return null;
    return .{
        .node = id,
        .where = where,
        .lang = meta.lang,
        .span = span,
        .body = bodyOf(host, span),
    };
}

/// The body of a fenced block spanning `span`: from past the opening fence's
/// line ending to the start of the closing fence's line.
fn bodyOf(host: []const u8, span: Span) Span {
    const block = host[span.start..span.end];
    const open_end = if (std.mem.indexOfScalar(u8, block, '\n')) |i| span.start + i + 1 else span.end;
    const close_start = if (std.mem.lastIndexOfScalar(u8, block, '\n')) |i| span.start + i + 1 else span.end;
    return Span.init(open_end, @max(open_end, close_start));
}

/// The fig dialect a fence's language tag names, or null when fig has none
/// registered under it. Tags are matched case-insensitively, and the
/// spellings fig's `Embed` read before 6.0 still read: `fig` is figl, `yml`
/// is YAML.
pub fn dialectFor(lang: []const u8) ?*const fig.Runtime.Entry {
    var buf: [32]u8 = undefined;
    if (lang.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, lang);
    const aliases = [_]struct { []const u8, []const u8 }{
        .{ "fig", "figl" },
        .{ "yml", "yaml" },
    };
    for (aliases) |a| if (std.mem.eql(u8, lower, a[0])) return fig.Runtime.entryByName(a[1]);
    return fig.Runtime.entryByName(lower);
}

pub const OpenError = error{
    /// The document has no metadata block where one was asked for.
    NoMetadata,
    /// The block's language is not one fig has registered.
    UnsupportedLanguage,
} || Allocator.Error;

/// A fig `Editor` over a document's metadata block. Edit through `editor`;
/// `render` gives the host back with the edited body in place.
pub const Embed = struct {
    allocator: Allocator,
    /// The host before the body, the opening fence included.
    before: []u8,
    /// The host after the body, from the closing fence on.
    after: []u8,
    /// The body, as a config document. Its `source` is the body now.
    editor: fig.Editor(fig.Runtime.Language),
    /// The dialect the body is edited as.
    dialect: *const fig.Runtime.Entry,
    lang: []u8,

    /// Open the block `block` locates in `host`.
    pub fn open(allocator: Allocator, host: []const u8, block: Block) !Embed {
        const dialect = dialectFor(block.lang) orelse return error.UnsupportedLanguage;
        return openParts(
            allocator,
            host[0..block.body.start],
            host[block.body.start..block.body.end],
            host[block.body.end..],
            dialect,
            block.lang,
        );
    }

    /// Open `host`'s frontmatter, or — when it has none — a new block of
    /// `lang` above its first line, empty until an edit writes to it. Only a
    /// Markdown host is read for an existing block; `fmt` names its dialect.
    pub fn openOrInit(allocator: Allocator, host: []const u8, fmt: twig.Format, lang: []const u8) !Embed {
        var parsed = try parseHost(allocator, host, fmt);
        defer parsed.deinit();
        if (find(&parsed.doc, host, .front)) |block| return open(allocator, host, block);

        const dialect = dialectFor(lang) orelse return error.UnsupportedLanguage;
        const fence = try fenceFor(allocator, lang);
        defer allocator.free(fence);
        const before = try std.mem.concat(allocator, u8, &.{ fence, "\n" });
        defer allocator.free(before);
        const after = try std.mem.concat(allocator, u8, &.{ closerFor(lang), "\n", host });
        defer allocator.free(after);
        return openParts(allocator, before, "", after, dialect, lang);
    }

    fn openParts(
        allocator: Allocator,
        before: []const u8,
        content: []const u8,
        after: []const u8,
        dialect: *const fig.Runtime.Entry,
        lang: []const u8,
    ) !Embed {
        var self: Embed = .{
            .allocator = allocator,
            .before = try allocator.dupe(u8, before),
            .after = undefined,
            .editor = .{ .allocator = allocator, .format = dialect.typeOf() },
            .dialect = dialect,
            .lang = undefined,
        };
        errdefer allocator.free(self.before);
        self.after = try allocator.dupe(u8, after);
        errdefer allocator.free(self.after);
        self.lang = try allocator.dupe(u8, lang);
        errdefer allocator.free(self.lang);
        errdefer self.editor.deinit();
        try self.editor.init(content);
        return self;
    }

    /// The body as the editor holds it now.
    pub fn body(self: *const Embed) []const u8 {
        return self.editor.source.items;
    }

    /// The host with the edited body between its fences. A body that does
    /// not end its last line is given a line ending, so the closing fence
    /// stays on a line of its own.
    pub fn render(self: *const Embed, allocator: Allocator) Allocator.Error![]u8 {
        const b = self.body();
        const nl: []const u8 = if (b.len > 0 and b[b.len - 1] != '\n') "\n" else "";
        return std.mem.concat(allocator, u8, &.{ self.before, b, nl, self.after });
    }

    pub fn deinit(self: *Embed) void {
        self.editor.deinit();
        self.allocator.free(self.before);
        self.allocator.free(self.after);
        self.allocator.free(self.lang);
    }
};

/// The opening fence a new frontmatter block of `lang` is written with: a
/// bare `---` for YAML, the convention twig reads as YAML, a bare `+++` for
/// TOML, and `---<lang>` for any other.
fn fenceFor(allocator: Allocator, lang: []const u8) Allocator.Error![]u8 {
    if (std.ascii.eqlIgnoreCase(lang, "yaml")) return allocator.dupe(u8, "---");
    if (std.ascii.eqlIgnoreCase(lang, "toml")) return allocator.dupe(u8, "+++");
    return std.mem.concat(allocator, u8, &.{ "---", lang });
}

fn closerFor(lang: []const u8) []const u8 {
    return if (std.ascii.eqlIgnoreCase(lang, "toml")) "+++" else "---";
}

/// Parse `host` as `fmt` with its default extensions (frontmatter on).
pub fn parseHost(allocator: Allocator, host: []const u8, fmt: twig.Format) !twig.format.ParsedDoc {
    const cfg: twig.format.ParseConfig = .{};
    return twig.format.entryFor(fmt).parse(&cfg, allocator, host);
}

/// Read the document's metadata block at `where` as a fig `Document`, or
/// null when it has none. The returned document borrows `host`.
pub fn read(allocator: Allocator, host: []const u8, doc: *const twig.Document, where: Where) !?fig.Document {
    const block = find(doc, host, where) orelse return null;
    const dialect = dialectFor(block.lang) orelse return error.UnsupportedLanguage;
    return try fig.Runtime.Language.Parser.parse(allocator, host[block.body.start..block.body.end], dialect.typeOf());
}

/// How `host` asks to be read: the format and config its frontmatter's
/// `twig` settings (`Settings`) lay over `fmt` and the caller's `config`,
/// and the names among them twig did not act on. A host with no frontmatter,
/// or frontmatter in a language fig has not registered, is read as asked.
pub const Resolved = struct {
    format: twig.Format,
    config: twig.format.ParseConfig,
    /// Borrowed from `settings`' metadata; empty when nothing was ignored.
    ignored: []const []const u8,
    settings: Settings,
    meta: ?fig.Document,

    pub fn deinit(self: *Resolved, allocator: Allocator) void {
        self.settings.deinit(allocator);
        if (self.meta) |m| m.deinit(allocator);
    }
};

/// Resolve `host`'s settings (see `Resolved`). The frontmatter is found with
/// `fmt`'s own row and the caller's config, which every Markdown row reads
/// alike, so the settings cannot change where they themselves are.
pub fn resolve(allocator: Allocator, host: []const u8, fmt: twig.Format, config: twig.format.ParseConfig) !Resolved {
    var out: Resolved = .{ .format = fmt, .config = config, .ignored = &.{}, .settings = .{}, .meta = null };
    var parsed = try twig.format.entryFor(fmt).parse(&config, allocator, host);
    defer parsed.deinit();
    const block = find(&parsed.doc, host, .front) orelse return out;
    const dialect = dialectFor(block.lang) orelse return out;
    // Frontmatter that does not parse holds no settings: the document is
    // still read, as asked.
    out.meta = fig.Runtime.Language.Parser.parse(allocator, host[block.body.start..block.body.end], dialect.typeOf()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return out,
    };
    errdefer out.deinit(allocator);
    out.settings = try Settings.read(allocator, &out.meta.?, fmt);
    const applied = try out.settings.apply(allocator, fmt, config);
    out.format = applied.format;
    out.config = applied.config;
    out.ignored = out.settings.ignored.items;
    return out;
}

test {
    _ = Settings;
    _ = @import("meta_test.zig");
}
