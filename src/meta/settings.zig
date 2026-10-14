//! Render settings a document carries in its own metadata.
//!
//! A document says how it should be read under a `twig` key:
//!
//! ```yaml
//! ---
//! title: Notes
//! twig:
//!   dialect: gfm
//!   features: [math, highlight]
//! ---
//! ```
//!
//! `dialect` names a row of the host's language (`gfm`, `commonmark`), and
//! `features` names the features that row lays over its own — Markdown's
//! extensions, or a runtime language's declared features — by the names
//! `twig.format.features` gives them. Settings only add: a caller's own
//! config is laid under them (`apply`), and a name twig does not know is
//! reported in `ignored`, never an error, since a document read by an older
//! twig should still render.

const std = @import("std");
const Allocator = std.mem.Allocator;

const twig = @import("twig");
const fig = @import("fig");

const Settings = @This();

/// The row the document asks to be read as, when it names one of its own
/// language's rows.
dialect: ?twig.Format = null,
/// The features it asks for, by name. Borrowed from the metadata document.
features: std.ArrayList([]const u8) = .empty,
/// Names under `twig` this twig does not act on: unknown keys, a dialect of
/// another language, a feature value that is not a string. Borrowed.
ignored: std.ArrayList([]const u8) = .empty,

pub fn deinit(self: *Settings, allocator: Allocator) void {
    self.features.deinit(allocator);
    self.ignored.deinit(allocator);
}

/// The settings `meta` — a document's parsed metadata — holds for a host of
/// format `host`. A document with no `twig` key has none.
pub fn read(allocator: Allocator, meta: *const fig.Document, host: twig.Format) Allocator.Error!Settings {
    var self: Settings = .{};
    errdefer self.deinit(allocator);
    const ast = &meta.ast;
    const root = ast.getValByPath(&.{.{ .key = "twig" }}) catch return self;
    if (root.kind != .mapping) {
        try self.ignored.append(allocator, "twig");
        return self;
    }
    var entry = (ast.child(&root) catch null) orelse return self;
    while (true) {
        const kv = entry.kind.keyvalue;
        const key = ast.node(kv.key);
        const value = ast.node(kv.value);
        const name: []const u8 = switch (key.kind) {
            .string => |s| s,
            else => "",
        };
        if (std.mem.eql(u8, name, "dialect")) {
            self.dialect = switch (value.kind) {
                .string => |s| dialectOf(host, s),
                else => null,
            };
            if (self.dialect == null) try self.ignored.append(allocator, name);
        } else if (std.mem.eql(u8, name, "features")) {
            try self.readFeatures(allocator, ast, value);
        } else {
            try self.ignored.append(allocator, name);
        }
        entry = ast.next(&entry) orelse break;
    }
    return self;
}

fn readFeatures(self: *Settings, allocator: Allocator, ast: *const fig.AST, value: fig.AST.Node) Allocator.Error!void {
    switch (value.kind) {
        // A single feature may be written on its own, without a list.
        .string => |s| return self.features.append(allocator, s),
        .sequence => {},
        else => return self.ignored.append(allocator, "features"),
    }
    var item = (ast.child(&value) catch null) orelse return;
    while (true) {
        switch (item.kind) {
            .string => |s| try self.features.append(allocator, s),
            else => try self.ignored.append(allocator, "features"),
        }
        item = ast.next(&item) orelse break;
    }
}

/// `name` as a row of `host`'s language: `host` itself, or a dialect of the
/// same language. Null for an unknown name or another language's row.
fn dialectOf(host: twig.Format, name: []const u8) ?twig.Format {
    const f = twig.format.parseFormatName(name) orelse return null;
    return if (languageOf(f) == languageOf(host)) f else null;
}

fn languageOf(f: twig.Format) twig.Format {
    return twig.format.entryFor(f).dialect_of orelse f;
}

/// The format and config to read a document of `host` with, given the
/// caller's own `config`: the document's dialect, when it names one, and its
/// features laid over the caller's. A feature `fmt` does not declare is
/// added to `ignored`.
pub fn apply(
    self: *Settings,
    allocator: Allocator,
    host: twig.Format,
    config: twig.format.ParseConfig,
) Allocator.Error!struct { format: twig.Format, config: twig.format.ParseConfig } {
    const fmt = self.dialect orelse host;
    var mask = maskOf(fmt, config);
    for (self.features.items) |name| {
        if (twig.format.featureBit(fmt, name)) |bit| {
            mask |= bit;
        } else {
            try self.ignored.append(allocator, name);
        }
    }
    return .{ .format = fmt, .config = twig.format.ParseConfig.forFeatures(fmt, mask) };
}

/// The feature bits `config` already turns on for `fmt`.
fn maskOf(fmt: twig.Format, config: twig.format.ParseConfig) u32 {
    var mask: u32 = config.features;
    for (twig.format.features(fmt), 0..) |f, i| {
        inline for (comptime std.meta.fieldNames(@TypeOf(config.markdown))) |field| {
            if (std.mem.eql(u8, f.name, field) and @field(config.markdown, field)) mask |= @as(u32, 1) << @intCast(i);
        }
    }
    return mask;
}
