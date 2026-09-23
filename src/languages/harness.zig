//! Registry-wide engine contracts. Corpora belong to conformance readers.
//!
//! The checks are `contract.zig`'s, which registration runs over a runtime
//! language too; this file is the loop over the compiled registry, plus the
//! one property that belongs to core's encoder rather than to a format — the
//! node table's identity over every sample.
const std = @import("std");
const testing = std.testing;
const format = @import("../format.zig");
const contract = @import("../contract.zig");
const node_table = @import("../ast/table.zig");

fn expectKept(result: contract.Error!void, report: *const contract.Report) !void {
    result catch |err| {
        std.debug.print("\n{s}\n", .{report.message()});
        return err;
    };
}

test "harness: every authorable format moves a block across its containers" {
    for (&format.registry) |*entry| {
        if (!entry.syntax.authorable()) continue;
        var report: contract.Report = .{};
        try expectKept(contract.moveBlock(testing.allocator, entry, &report), &report);
    }
}

test "harness: every declared renderer keeps the engine's promise" {
    for (&format.registry) |*entry| {
        var report: contract.Report = .{};
        try expectKept(contract.renderers(testing.allocator, entry, &report), &report);
    }
}

test "harness: every format declares samples and satisfies the engine contract" {
    for (&format.registry) |*entry| {
        var report: contract.Report = .{};
        try expectKept(contract.samples(testing.allocator, entry, &report), &report);
        // The compiled formats cross the contract a runtime one will: every
        // sample's parse, written as a node table and read back, is the parse.
        for (entry.samples, 0..) |sample, index| {
            errdefer std.debug.print("\n{s}: harness sample {d}\n--- source ---\n{s}\n", .{ entry.id.name(), index, sample });
            const config: format.ParseConfig = .{};
            var parsed = try entry.parse(&config, testing.allocator, sample);
            defer parsed.deinit();
            try node_table.expectIdentity(testing.allocator, &parsed.doc);
        }
    }
}

test "harness: a broken promise is reported, not asserted" {
    // A row whose samples are fine but whose renderer lies: djot's own row
    // with a `renderBlock` that prints nothing. The contract names the check
    // and the format rather than failing an expectation somewhere inside.
    const Lying = struct {
        fn render(_: std.mem.Allocator, _: *const @import("../ast/ast.zig"), _: @import("../ast/ast.zig").Node.Id, _: *std.Io.Writer) anyerror!void {}
    };
    var table = format.syntaxFor(.djot).*;
    table.renderBlock = &Lying.render;
    var entry = format.entryFor(.djot).*;
    entry.syntax = &table;
    entry.syntaxFor = null;
    var report: contract.Report = .{};
    try testing.expectError(error.ContractBroken, contract.renderBlock(testing.allocator, &entry, &report));
    try testing.expect(std.mem.startsWith(u8, report.message(), "djot: renderBlock:"));
}
