const std = @import("std");
const Io = std.Io;
const nbt = @import("nbt.zig");

pub const MojangBlockProperty = struct {
    name: []const u8,
    type: []const u8,
    values: []struct { value: std.json.Value },
};

pub const MojangDataItem = struct {
    name: []const u8,
    properties: []struct { name: []const u8 },
};

pub const MojangBlocks = struct {
    block_properties: []MojangBlockProperty,
    data_items: []MojangDataItem,
};

pub const BlockState = struct {
    identifier: []const u8,
    type: []const u8,
    values: []std.json.Value,
};

pub const BlockInfo = struct {
    identifier: []const u8,
    states: [][]const u8,
};

pub const Permutation = struct {
    identifier: []const u8,
    hash: i32,
    state: []nbt.StateProperty,
};

/// Derived block/permutation data. Owns the parsed docs JSON, so `parsed`
/// must outlive the slices that point into it. Call `deinit` when done.
pub const GameData = struct {
    parsed: std.json.Parsed(MojangBlocks),
    block_states: []BlockState,
    block_types: []BlockInfo,
    permutations: []Permutation,

    pub fn deinit(self: *GameData, allocator: std.mem.Allocator) void {
        allocator.free(self.block_states);
        allocator.free(self.block_types);
        allocator.free(self.permutations);
        self.parsed.deinit();
    }
};

/// Parse BDS's generated `mojang-blocks.json` and derive block states,
/// block types, and every permutation with its FNV-1a hash.
pub fn buildGameData(allocator: std.mem.Allocator, docs_raw: []const u8) !GameData {
    var parsed = try std.json.parseFromSlice(MojangBlocks, allocator, docs_raw, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    const palette = parsed.value;

    var block_states: std.ArrayList(BlockState) = .empty;
    defer block_states.deinit(allocator);
    for (palette.block_properties) |prop| {
        var raw_vals = try allocator.alloc(std.json.Value, prop.values.len);
        for (prop.values, 0..) |entry, i| {
            raw_vals[i] = entry.value;
        }
        try block_states.append(allocator, .{
            .identifier = prop.name,
            .type = prop.type,
            .values = raw_vals,
        });
    }

    var block_types: std.ArrayList(BlockInfo) = .empty;
    defer block_types.deinit(allocator);
    for (palette.data_items) |item| {
        var state_names: std.ArrayList([]const u8) = .empty;
        for (item.properties) |p| {
            try state_names.append(allocator, p.name);
        }
        try block_types.append(allocator, .{
            .identifier = item.name,
            .states = try state_names.toOwnedSlice(allocator),
        });
    }

    var permutations: std.ArrayList(Permutation) = .empty;
    defer permutations.deinit(allocator);

    for (block_types.items) |bt| {
        var values_list: std.ArrayList([]std.json.Value) = .empty;
        for (bt.states) |state_name| {
            const found_state = for (block_states.items) |bs| {
                if (std.mem.eql(u8, bs.identifier, state_name)) break bs;
            } else null;
            if (found_state) |fs| {
                try values_list.append(allocator, fs.values);
            }
        }

        const state_keys = bt.states;
        const state_values = try values_list.toOwnedSlice(allocator);

        var combo_results: std.ArrayList([]nbt.StateProperty) = .empty;
        defer combo_results.deinit(allocator);
        const current = try allocator.alloc(nbt.StateProperty, state_keys.len);

        try generatePermutations(allocator, state_keys, state_values, 0, current, &combo_results);

        for (combo_results.items) |combo| {
            const h = try nbt.computeHash(allocator, bt.identifier, combo);
            try permutations.append(allocator, .{
                .identifier = bt.identifier,
                .hash = h,
                .state = combo,
            });
        }
    }

    return .{
        .parsed = parsed,
        .block_states = try block_states.toOwnedSlice(allocator),
        .block_types = try block_types.toOwnedSlice(allocator),
        .permutations = try permutations.toOwnedSlice(allocator),
    };
}

/// Write the five dump JSON files into `dump_path`, merging addon data.
pub fn writeDumps(allocator: std.mem.Allocator, io: Io, dump_path: []const u8, data: *const GameData, addon_root: std.json.Value) !void {
    std.debug.print("Writing dump files...\n", .{});
    const block_states = data.block_states;
    const block_types = data.block_types;
    const permutations = data.permutations;
    const addon_types = addon_root.object.get("blockTypes").?.array;
    const addon_items = addon_root.object.get("itemTypes").?.array;
    const addon_entities = addon_root.object.get("entityTypes").?.array;

    // Write block_states.json manually
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, "[\n");
        for (block_states, 0..) |bs, i| {
            if (i > 0) try out.appendSlice(allocator, ",\n");
            try writeFmt(&out, allocator, "  {{\"identifier\":\"{s}\",\"type\":\"{s}\",\"values\":[", .{ bs.identifier, bs.type });
            for (bs.values, 0..) |v, j| {
                if (j > 0) try out.appendSlice(allocator, ",");
                switch (v) {
                    .string => |s| try writeFmt(&out, allocator, "\"{s}\"", .{s}),
                    .integer => |n| try writeFmt(&out, allocator, "{d}", .{n}),
                    .bool => |b| try writeFmt(&out, allocator, "{}", .{b}),
                    else => {},
                }
            }
            try out.appendSlice(allocator, "]}");
        }
        try out.appendSlice(allocator, "\n]\n");
        const states_file = try std.fs.path.join(allocator, &.{ dump_path, "block_states.json" });
        try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = states_file, .data = out.items });
    }

    // Write block_types.json
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, "[\n");
        for (block_types, 0..) |bt, i| {
            if (i > 0) try out.appendSlice(allocator, ",\n");
            try writeFmt(&out, allocator, "  {{\"identifier\":\"{s}\",\"states\":[", .{bt.identifier});
            for (bt.states, 0..) |s, j| {
                if (j > 0) try out.appendSlice(allocator, ",");
                try writeFmt(&out, allocator, "\"{s}\"", .{s});
            }
            try out.appendSlice(allocator, "]");
            for (addon_types.items) |abt_val| {
                const abt_id = abt_val.object.get("identifier").?.string;
                if (std.mem.eql(u8, abt_id, bt.identifier)) {
                    if (abt_val.object.get("loggable")) |lg| {
                        try writeFmt(&out, allocator, ",\"loggable\":{}", .{lg.bool});
                    }
                    break;
                }
            }
            try out.appendSlice(allocator, "}");
        }
        try out.appendSlice(allocator, "\n]\n");
        const types_file = try std.fs.path.join(allocator, &.{ dump_path, "block_types.json" });
        try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = types_file, .data = out.items });
    }

    // Write item_types.json
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var buf: [1024 * 1024]u8 = undefined;
        var fbs = Io.Writer.fixed(&buf);
        try std.json.fmt(addon_items.items, .{ .whitespace = .indent_2 }).format(&fbs);
        try out.appendSlice(allocator, Io.Writer.buffered(&fbs));
        const items_file = try std.fs.path.join(allocator, &.{ dump_path, "item_types.json" });
        try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = items_file, .data = out.items });
    }

    // Write entity_types.json
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var buf: [1024 * 1024]u8 = undefined;
        var fbs = Io.Writer.fixed(&buf);
        try std.json.fmt(addon_entities.items, .{ .whitespace = .indent_2 }).format(&fbs);
        try out.appendSlice(allocator, Io.Writer.buffered(&fbs));
        const entities_file = try std.fs.path.join(allocator, &.{ dump_path, "entity_types.json" });
        try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = entities_file, .data = out.items });
    }

    // Write block_permutations.json
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, "[\n");
        for (permutations, 0..) |p, i| {
            if (i > 0) try out.appendSlice(allocator, ",\n");
            try writeFmt(&out, allocator, "  {{\"identifier\":\"{s}\",\"hash\":{d},\"state\":{{", .{ p.identifier, p.hash });
            for (p.state, 0..) |sp, j| {
                if (j > 0) try out.appendSlice(allocator, ",");
                try writeFmt(&out, allocator, "\"{s}\":", .{sp.key});
                switch (sp.value) {
                    .int => |v| try writeFmt(&out, allocator, "{d}", .{v}),
                    .string => |v| try writeFmt(&out, allocator, "\"{s}\"", .{v}),
                    .boolean => |v| try writeFmt(&out, allocator, "{}", .{v}),
                }
            }
            try out.appendSlice(allocator, "}}");
        }
        try out.appendSlice(allocator, "\n]\n");
        const perm_file = try std.fs.path.join(allocator, &.{ dump_path, "block_permutations.json" });
        try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = perm_file, .data = out.items });
    }
}

fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) !nbt.StateEntry {
    return switch (value) {
        .integer => |v| .{ .int = @intCast(v) },
        .float => |v| .{ .int = @intFromFloat(v) },
        .number_string => |v| {
            if (std.mem.indexOfScalar(u8, v, '.')) |_| {
                const f = try std.fmt.parseFloat(f64, v);
                return .{ .int = @intFromFloat(f) };
            }
            return .{ .int = @intCast(try std.fmt.parseInt(i64, v, 10)) };
        },
        .string => |v| .{ .string = try allocator.dupe(u8, v) },
        .bool => |v| .{ .boolean = v },
        else => error.InvalidValue,
    };
}

fn generatePermutations(
    allocator: std.mem.Allocator,
    state_keys: []const []const u8,
    state_values: []const []std.json.Value,
    idx: usize,
    current: []nbt.StateProperty,
    results: *std.ArrayList([]nbt.StateProperty),
) !void {
    if (idx >= state_keys.len) {
        const copy = try allocator.alloc(nbt.StateProperty, current.len);
        @memcpy(copy, current);
        try results.append(allocator, copy);
        return;
    }

    const key = state_keys[idx];
    const values = state_values[idx];

    for (values) |*val| {
        const entry = try parseValue(allocator, val.*);
        current[idx] = .{ .key = key, .value = entry };
        try generatePermutations(allocator, state_keys, state_values, idx + 1, current, results);
    }
}

fn writeFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt_str: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt_str, args);
    try out.appendSlice(allocator, s);
}
