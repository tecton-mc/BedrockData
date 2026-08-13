const std = @import("std");
const Io = std.Io;

const bs = @import("BinaryStream");
const BinaryStream = bs.BinaryStream;
const Endian = bs.Endianess;
const nbt = @import("mc_nbt");

const bds = @import("bds.zig");
const dump = @import("dump.zig");
const local_nbt = @import("nbt.zig");

const Entry = struct {
    name: []const u8,
    meta: u16,
    compound: nbt.CompoundTag,
};

const Warning = struct {
    name: []const u8,
    meta: u16,
    identifier: []const u8,
    reason: []const u8,
};

const Stats = struct {
    matched: usize,
    injected: usize,
    warnings: []const Warning,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    cwd: []const u8,
    dump_path: []const u8,
    block_states: []const dump.BlockState,
    block_types: []const dump.BlockInfo,
    permutations: []const dump.Permutation,
) !void {
    const bin_path = try std.fs.path.join(allocator, &.{ cwd, "r12_to_current_block_map.bin" });
    const raw = bds.readFileAlloc(io, allocator, bin_path) catch |err| {
        std.debug.print("r12: skipping (cannot read {s}): {s}\n", .{ bin_path, @errorName(err) });
        return;
    };

    const entries = try parseBase(allocator, raw);
    const required_map = try buildRequiredMap(allocator, block_types);
    const state_defs = try buildStateDefs(allocator, block_states);
    const perm_hashes = try buildPermHashSet(allocator, permutations);

    var out_stream = BinaryStream.init(allocator, null, null);
    defer out_stream.deinit();

    const stats = try enrich(allocator, entries, &required_map, &state_defs, &perm_hashes, &out_stream);

    const out_path = try std.fs.path.join(allocator, &.{ dump_path, "r12_to_current_block_map.bin" });
    try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = out_path, .data = out_stream.getBuffer() });
    try writeWarnings(allocator, io, dump_path, stats.warnings);

    std.debug.print("r12: matched {d}/{d} entries, injected {d} defaults, {d} warnings\n", .{
        stats.matched, entries.len, stats.injected, stats.warnings.len,
    });
}

fn enrich(
    allocator: std.mem.Allocator,
    entries: []Entry,
    required_map: *const std.StringHashMapUnmanaged([]const []const u8),
    state_defs: *const std.StringHashMapUnmanaged(*const dump.BlockState),
    perm_hashes: *const std.AutoHashMapUnmanaged(i32, void),
    out_stream: *BinaryStream,
) !Stats {
    var warnings: std.ArrayList(Warning) = .empty;
    var matched: usize = 0;
    var injected: usize = 0;

    for (entries) |*entry| {
        const identifier = getIdentifier(entry.compound) orelse {
            try addWarning(&warnings, allocator, entry.*, "", "missing or non-string name tag");
            continue;
        };

        const required_keys = required_map.get(identifier) orelse {
            try addWarning(&warnings, allocator, entry.*, identifier, "block not present in target version");
            continue;
        };

        const states_tag = entry.compound.value.getPtr("states") orelse {
            try addWarning(&warnings, allocator, entry.*, identifier, "missing states compound");
            continue;
        };
        const states = switch (states_tag.*) {
            .Compound => |*c| c,
            else => {
                try addWarning(&warnings, allocator, entry.*, identifier, "states is not a compound");
                continue;
            },
        };

        // Permutations hash properties in block_types order, so build the
        // property list following that order, injecting defaults as needed.
        var props: std.ArrayList(local_nbt.StateProperty) = .empty;
        var ok = true;
        for (required_keys) |key| {
            if (states.value.get(key)) |value_tag| {
                const value = extractStateEntry(value_tag) orelse {
                    try addWarning(&warnings, allocator, entry.*, identifier, "unsupported state tag type");
                    ok = false;
                    break;
                };
                try props.append(allocator, .{ .key = key, .value = value });
            } else {
                const def = state_defs.get(key) orelse {
                    try addWarning(&warnings, allocator, entry.*, identifier, "missing state default");
                    ok = false;
                    break;
                };
                const tag = makeDefaultTag(def) catch {
                    try addWarning(&warnings, allocator, entry.*, identifier, "invalid state default value");
                    ok = false;
                    break;
                };
                try states.set(key, tag);
                try props.append(allocator, .{ .key = key, .value = extractStateEntry(tag).? });
                injected += 1;
            }
        }
        if (!ok) continue;

        const hash = try local_nbt.computeHash(allocator, identifier, props.items);
        if (!perm_hashes.contains(hash)) {
            try addWarning(&warnings, allocator, entry.*, identifier, "no matching permutation");
            continue;
        }

        matched += 1;
        try out_stream.writeVarString(entry.name);
        try out_stream.writeUShort(entry.meta, Endian.Little);
        try nbt.CompoundTag.write(out_stream, &entry.compound, .network);
    }

    return .{
        .matched = matched,
        .injected = injected,
        .warnings = try warnings.toOwnedSlice(allocator),
    };
}

fn addWarning(
    warnings: *std.ArrayList(Warning),
    allocator: std.mem.Allocator,
    entry: Entry,
    identifier: []const u8,
    reason: []const u8,
) !void {
    try warnings.append(allocator, .{
        .name = entry.name,
        .meta = entry.meta,
        .identifier = identifier,
        .reason = reason,
    });
}

fn parseBase(allocator: std.mem.Allocator, raw: []const u8) ![]Entry {
    var stream = BinaryStream.init(allocator, raw, null);
    var entries: std.ArrayList(Entry) = .empty;
    while (!stream.isEof()) {
        const name = try stream.readVarString();
        const meta = try stream.readUShort(Endian.Little);
        const compound = try nbt.CompoundTag.read(&stream, allocator, .network);
        try entries.append(allocator, .{ .name = name, .meta = meta, .compound = compound });
    }
    return entries.toOwnedSlice(allocator);
}

fn getIdentifier(compound: nbt.CompoundTag) ?[]const u8 {
    return switch (compound.get("name") orelse return null) {
        .String => |s| s.value,
        else => null,
    };
}

fn extractStateEntry(tag: nbt.Tag) ?local_nbt.StateEntry {
    return switch (tag) {
        .Byte => |b| .{ .boolean = b.value != 0 },
        .Int => |v| .{ .int = v.value },
        .String => |s| .{ .string = s.value },
        else => null,
    };
}

fn makeDefaultTag(def: *const dump.BlockState) !nbt.Tag {
    if (def.values.len == 0) return error.EmptyValues;
    const first = def.values[0];
    if (std.mem.eql(u8, def.type, "int")) {
        const value: i32 = switch (first) {
            .integer => |n| @intCast(n),
            .bool => |b| @intFromBool(b),
            else => return error.InvalidDefault,
        };
        return .{ .Int = .{ .value = value, .name = null } };
    }
    if (std.mem.eql(u8, def.type, "bool")) {
        const value: bool = switch (first) {
            .bool => |b| b,
            .integer => |n| n != 0,
            else => return error.InvalidDefault,
        };
        return .{ .Byte = .{ .value = @intFromBool(value), .name = null } };
    }
    const value: []const u8 = switch (first) {
        .string => |s| s,
        else => return error.InvalidDefault,
    };
    return .{ .String = .{ .value = value, .name = null } };
}

fn buildRequiredMap(
    allocator: std.mem.Allocator,
    block_types: []const dump.BlockInfo,
) !std.StringHashMapUnmanaged([]const []const u8) {
    var map: std.StringHashMapUnmanaged([]const []const u8) = .{};
    for (block_types) |bt| {
        try map.put(allocator, bt.identifier, bt.states);
    }
    return map;
}

fn buildStateDefs(
    allocator: std.mem.Allocator,
    block_states: []const dump.BlockState,
) !std.StringHashMapUnmanaged(*const dump.BlockState) {
    var map: std.StringHashMapUnmanaged(*const dump.BlockState) = .{};
    for (block_states) |*state| {
        try map.put(allocator, state.identifier, state);
    }
    return map;
}

fn buildPermHashSet(
    allocator: std.mem.Allocator,
    permutations: []const dump.Permutation,
) !std.AutoHashMapUnmanaged(i32, void) {
    var set: std.AutoHashMapUnmanaged(i32, void) = .{};
    for (permutations) |p| {
        try set.put(allocator, p.hash, {});
    }
    return set;
}

fn writeWarnings(
    allocator: std.mem.Allocator,
    io: Io,
    dump_path: []const u8,
    warnings: []const Warning,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var buf: [1024 * 1024]u8 = undefined;
    var fbs = Io.Writer.fixed(&buf);
    try std.json.fmt(warnings, .{ .whitespace = .indent_2 }).format(&fbs);
    try out.appendSlice(allocator, Io.Writer.buffered(&fbs));
    const path = try std.fs.path.join(allocator, &.{ dump_path, "r12_warnings.json" });
    try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = out.items });
}
