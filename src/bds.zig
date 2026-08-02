const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const cli = @import("cli.zig");
const http = @import("http.zig");

pub fn exeName() []const u8 {
    return if (builtin.os.tag == .linux) "bedrock_server" else "bedrock_server.exe";
}

pub fn readFileAlloc(io: Io, allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    const file = try Io.Dir.openFile(.cwd(), io, sub_path, .{});
    defer file.close(io);
    const stat = try Io.File.stat(file, io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    _ = try Io.File.readPositionalAll(file, io, buf, 0);
    return buf;
}

/// Kill any stale bedrock_server left over from an interrupted run so its
/// ports (19132/19133) are free. Best-effort: ignores errors.
pub fn killStaleBds(io: Io) void {
    if (std.process.spawn(io, .{ .argv = if (builtin.os.tag == .windows)
        &.{ "taskkill", "/F", "/IM", "bedrock_server.exe" }
    else
        &.{ "pkill", "-x", "bedrock_server" } })) |pk_result| {
        var pk_child = pk_result;
        _ = pk_child.wait(io) catch {};
    } else |_| {}
}

/// Download and extract BDS `target.version` into `server_path`, replacing
/// any previous install (stale packs included).
pub fn downloadBds(allocator: std.mem.Allocator, io: Io, server_path: []const u8, target: cli.TargetVersion) !void {
    const platform_str: []const u8 = if (builtin.os.tag == .linux) "linux" else "windows";

    const platform_dir = if (target.is_preview)
        try std.fmt.allocPrint(allocator, "{s}_preview", .{platform_str})
    else
        platform_str;

    const version_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/Bedrock-OSS/BDS-Versions/main/{s}/{s}.json", .{ platform_dir, target.version });

    const version_json = try http.runCurl(allocator, io, version_url);
    const vparsed = try std.json.parseFromSlice(struct { download_url: []const u8 }, allocator, version_json, .{ .ignore_unknown_fields = true });
    defer vparsed.deinit();

    const download_url = vparsed.value.download_url;

    // Clear the server dir so stale packs from a previously installed BDS
    // version (e.g. vanilla_1.26.40) do not linger and break the new one.
    std.debug.print("Cleaning server directory...\n", .{});
    try clearDirContents(allocator, io, server_path);

    const zip_path = try std.fs.path.join(allocator, &.{ server_path, "bedrock_server.zip" });

    std.debug.print("Downloading BDS...\n", .{});
    var curl = try std.process.spawn(io, .{
        .argv = &.{ "curl", "-L", "-f", "-A", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36", "-o", zip_path, download_url },
    });
    const dl_term = try curl.wait(io);
    if (dl_term.exited != 0) {
        std.debug.print("curl exited with code: {d}\n", .{dl_term.exited});
        return error.DownloadFailed;
    }
    std.debug.print("Download complete.\n", .{});

    std.debug.print("Extracting BDS...\n", .{});
    var unzip = try std.process.spawn(io, .{
        .argv = if (builtin.os.tag == .windows)
            &.{ "tar", "-xf", zip_path }
        else
            &.{ "unzip", "-o", zip_path },
        .cwd = .{ .path = server_path },
    });
    const term = try unzip.wait(io);
    if (term.exited != 0) {
        std.debug.print("unzip exited with code: {d}\n", .{term.exited});
        return error.UnzipFailed;
    }

    Io.Dir.deleteFile(.cwd(), io, zip_path) catch {};

    if (builtin.os.tag == .linux) {
        const exe_path = try std.fs.path.join(allocator, &.{ server_path, "bedrock_server" });
        var chmod_cmd = try std.process.spawn(io, .{
            .argv = &.{ "chmod", "+x", exe_path },
        });
        _ = try chmod_cmd.wait(io);
    }

    const marker_path = try std.fs.path.join(allocator, &.{ server_path, ".bds-version" });
    try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = marker_path, .data = target.version });

    std.debug.print("BDS ready.\n", .{});
}

/// Ensure the installed BDS matches `target.version`, downloading it if not.
pub fn ensureInstalled(allocator: std.mem.Allocator, io: Io, server_path: []const u8, worlds_path: []const u8, target: cli.TargetVersion) !void {
    const bds_exe_path = try std.fs.path.join(allocator, &.{ server_path, exeName() });

    const matches = blk: {
        Io.Dir.access(.cwd(), io, bds_exe_path, .{}) catch break :blk false;
        const marker_path = try std.fs.path.join(allocator, &.{ server_path, ".bds-version" });
        const marker_raw = readFileAlloc(io, allocator, marker_path) catch break :blk false;
        break :blk std.mem.eql(u8, std.mem.trim(u8, marker_raw, " \n"), target.version);
    };

    if (matches) return;

    std.debug.print("BDS {s} not installed. Downloading...\n", .{target.version});
    try downloadBds(allocator, io, server_path, target);
    // downloadBds cleared the server dir, so recreate the worlds dir.
    Io.Dir.createDir(.cwd(), io, worlds_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

/// Ensure `@minecraft/server-net` is listed in `server_path`'s permissions.
pub fn patchPermissions(allocator: std.mem.Allocator, io: Io, perm_path: []const u8) !void {
    const perm_raw = try readFileAlloc(io, allocator, perm_path);

    const ParsedPerm = struct { allowed_modules: []const []const u8 };
    var perm_parsed = try std.json.parseFromSlice(ParsedPerm, allocator, perm_raw, .{});
    defer perm_parsed.deinit();

    for (perm_parsed.value.allowed_modules) |m| {
        if (std.mem.eql(u8, m, "@minecraft/server-net")) return;
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "{\n  \"allowed_modules\": [\n");
    for (perm_parsed.value.allowed_modules, 0..) |m, i| {
        if (i > 0) try out.appendSlice(allocator, ",\n");
        const quoted = try std.fmt.allocPrint(allocator, "    \"{s}\"", .{m});
        try out.appendSlice(allocator, quoted);
    }
    try out.appendSlice(allocator, ",\n    \"@minecraft/server-net\"\n  ]\n}\n");
    try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = perm_path, .data = out.items });
}

pub fn copyDirRecursive(allocator: std.mem.Allocator, io: Io, src_path: []const u8, dst_path: []const u8) !void {
    var src_dir = try Io.Dir.openDir(.cwd(), io, src_path, .{ .iterate = true });
    defer src_dir.close(io);

    Io.Dir.createDir(.cwd(), io, dst_path, .default_dir) catch {};

    var iter = Io.Dir.iterate(src_dir);
    while (try iter.next(io)) |entry| {
        const src_full = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        const dst_full = try std.fs.path.join(allocator, &.{ dst_path, entry.name });

        switch (entry.kind) {
            .file => {
                try Io.Dir.copyFile(.cwd(), src_full, .cwd(), dst_full, io, .{});
            },
            .directory => {
                try copyDirRecursive(allocator, io, src_full, dst_full);
            },
            else => {},
        }
    }
}

pub fn removeDirRecursive(allocator: std.mem.Allocator, io: Io, dir_path: []const u8) !void {
    var dir = Io.Dir.openDir(.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(io);

    var iter = Io.Dir.iterate(dir);
    while (try iter.next(io)) |entry| {
        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .file => {
                Io.Dir.deleteFile(.cwd(), io, full) catch {};
            },
            .directory => {
                try removeDirRecursive(allocator, io, full);
            },
            else => {},
        }
    }
    Io.Dir.deleteDir(.cwd(), io, dir_path) catch {};
}

fn clearDirContents(allocator: std.mem.Allocator, io: Io, dir_path: []const u8) !void {
    var dir = Io.Dir.openDir(.cwd(), io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(io);

    var iter = Io.Dir.iterate(dir);
    while (try iter.next(io)) |entry| {
        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .file => {
                Io.Dir.deleteFile(.cwd(), io, full) catch {};
            },
            .directory => {
                try removeDirRecursive(allocator, io, full);
            },
            else => {},
        }
    }
}
