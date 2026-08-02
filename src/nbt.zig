const std = @import("std");

pub const StateEntry = union(enum) {
    int: i32,
    string: []const u8,
    boolean: bool,
};

pub const StateProperty = struct {
    key: []const u8,
    value: StateEntry,
};

const NBT_BYTE: u8 = 1;
const NBT_INT: u8 = 3;
const NBT_STRING: u8 = 8;
const NBT_COMPOUND: u8 = 10;

const HASH_OFFSET: u32 = 0x811c9dc5;

fn writeNbtString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, @intCast(s.len & 0xFF));
    try buf.append(gpa, @intCast((s.len >> 8) & 0xFF));
    try buf.appendSlice(gpa, s);
}

pub fn computeHash(allocator: std.mem.Allocator, identifier: []const u8, properties: []const StateProperty) !i32 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, NBT_COMPOUND);
    try writeNbtString(&buf, allocator, "");

    try buf.append(allocator, NBT_STRING);
    try writeNbtString(&buf, allocator, "name");
    try writeNbtString(&buf, allocator, identifier);

    try buf.append(allocator, NBT_COMPOUND);
    try writeNbtString(&buf, allocator, "states");

    for (properties) |prop| {
        switch (prop.value) {
            .int => |v| {
                try buf.append(allocator, NBT_INT);
                try writeNbtString(&buf, allocator, prop.key);
                try buf.append(allocator, @intCast((v >> 24) & 0xFF));
                try buf.append(allocator, @intCast((v >> 16) & 0xFF));
                try buf.append(allocator, @intCast((v >> 8) & 0xFF));
                try buf.append(allocator, @intCast(v & 0xFF));
            },
            .string => |v| {
                try buf.append(allocator, NBT_STRING);
                try writeNbtString(&buf, allocator, prop.key);
                try writeNbtString(&buf, allocator, v);
            },
            .boolean => |v| {
                try buf.append(allocator, NBT_BYTE);
                try writeNbtString(&buf, allocator, prop.key);
                try buf.append(allocator, @intFromBool(v));
            },
        }
    }

    try buf.append(allocator, 0); // TAG_End for states
    try buf.append(allocator, 0); // TAG_End for root

    var hash: u32 = HASH_OFFSET;
    for (buf.items) |byte| {
        hash ^= byte;
        hash +%= (hash << 1) +% (hash << 4) +% (hash << 7) +% (hash << 8) +% (hash << 24);
    }
    return @as(i32, @bitCast(hash));
}
