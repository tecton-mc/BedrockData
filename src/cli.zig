const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const http = @import("http.zig");

pub const BDS_VERSIONS_URL = "https://raw.githubusercontent.com/Bedrock-OSS/BDS-Versions/main/versions.json";

pub const CliOptions = struct {
    list: bool = false,
    preview: bool = false,
    version: ?[]const u8 = null,
};

pub const TargetVersion = struct {
    version: []const u8,
    is_preview: bool,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !CliOptions {
    var opts = CliOptions{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            opts.list = true;
        } else if (std.mem.eql(u8, arg, "--preview") or std.mem.eql(u8, arg, "-p")) {
            opts.preview = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            i += 1;
            if (i >= args.len) return error.MissingVersionArg;
            opts.version = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printHelp();
            return error.InvalidOption;
        }
    }
    return opts;
}

fn printHelp() void {
    std.debug.print(
        \\bedrock-data - Dump Minecraft Bedrock Edition game data
        \\
        \\Usage: bedrock-data [options]
        \\
        \\Options:
        \\  -l, --list          List available stable and preview versions
        \\  -p, --preview       Use latest preview version instead of stable
        \\  -v, --version VER   Use a specific version (e.g. 1.26.36.1)
        \\  -h, --help          Show this help
        \\
    , .{});
}

// pub fn isValidVersion(allocator: std.mem.Allocator, io: Io, target: TargetVersion) !bool {
//     const platform_str: []const u8 = if (builtin.os.tag == .linux) "linux" else "windows";
//
//     const body = try http.runCurl(allocator, io, BDS_VERSIONS_URL);
//     const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
//     defer parsed.deinit();
//
//     const root = parsed.value;
//     const platform = root.object.get(platform_str).?.object;
//
//     var valid = false;
//
//     if (platform.get("versions")) |vers| {
//         for (vers.array.items) |v| {
//             if (std.mem.eql(u8, target.version, v.string)) {
//                 valid = true;
//             }
//         }
//     }
//
//     if (platform.get("preview_versions")) |vers| {
//         for (vers.array.items) |v| {
//             if (std.mem.eql(u8, target.version, v.string)) {
//                 valid = true;
//             }
//         }
//     }
//
//     return valid;
// }

pub fn listVersions(allocator: std.mem.Allocator, io: Io) !void {
    const platform_str: []const u8 = if (builtin.os.tag == .linux) "linux" else "windows";

    const body = try http.runCurl(allocator, io, BDS_VERSIONS_URL);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const platform = root.object.get(platform_str).?.object;

    const stable = platform.get("stable").?.string;
    const preview = platform.get("preview").?.string;

    std.debug.print("{s} versions:\n", .{platform_str});
    std.debug.print("  Latest stable:  {s}\n", .{stable});
    std.debug.print("  Latest preview: {s}\n", .{preview});
    std.debug.print("\nAll stable:\n", .{});
    if (platform.get("versions")) |vers| {
        for (vers.array.items) |v| {
            std.debug.print("  {s}\n", .{v.string});
        }
    }
    std.debug.print("\nAll preview:\n", .{});
    if (platform.get("preview_versions")) |prevs| {
        for (prevs.array.items) |v| {
            std.debug.print("  {s}\n", .{v.string});
        }
    }
}

pub fn resolveTargetVersion(allocator: std.mem.Allocator, io: Io, opts: CliOptions) !TargetVersion {
    const platform_str: []const u8 = if (builtin.os.tag == .linux) "linux" else "windows";

    std.debug.print("Fetching BDS version info...\n", .{});

    const versions_json = try http.runCurl(allocator, io, BDS_VERSIONS_URL);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, versions_json, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const platform = root.object.get(platform_str).?.object;

    var valid = false;

    if (platform.get("versions")) |vers| {
        for (vers.array.items) |v| {
            if (opts.version) |ver| {
                if (std.mem.eql(u8, ver, v.string)) valid = true;
            }
        }
    }

    if (platform.get("preview_versions")) |vers| {
        for (vers.array.items) |v| {
            if (opts.version) |ver| {
                if (std.mem.eql(u8, ver, v.string)) valid = true;
            }
        }
    }

    const target_version = if (opts.version) |ver| blk: {
        std.debug.print("Requested version: {s}\n", .{ver});
        break :blk ver;
    } else if (opts.preview) blk: {
        const pv = platform.get("preview").?.string;
        std.debug.print("Using latest preview: {s}\n", .{pv});
        break :blk pv;
    } else blk: {
        const st = platform.get("stable").?.string;
        std.debug.print("Using latest {s} stable: {s}\n", .{ platform_str, st });
        break :blk st;
    };

    const is_preview = blk: {
        const previews = platform.get("preview_versions") orelse break :blk false;
        for (previews.array.items) |v| {
            if (std.mem.eql(u8, v.string, target_version)) break :blk true;
        }
        break :blk false;
    };

    _ = if (!valid) {
        std.debug.print("Invalid version({s}), use -l to see available versions \n", .{target_version});
        std.process.exit(1);
    };

    return .{ .version = target_version, .is_preview = is_preview };
}
