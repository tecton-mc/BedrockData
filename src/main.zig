const std = @import("std");
const Io = std.Io;

const bds = @import("bds.zig");
const cli = @import("cli.zig");
const dump = @import("dump.zig");
const http = @import("http.zig");
const r12 = @import("r12.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    const opts = try cli.parseArgs(allocator, args);

    if (opts.list) {
        try cli.listVersions(allocator, io);
        return;
    }

    const cwd = try std.process.currentPathAlloc(io, allocator);
    const server_path = try std.fs.path.join(allocator, &.{ cwd, "server" });
    const dump_base_path = try std.fs.path.join(allocator, &.{ cwd, "dump" });
    const template_path = try std.fs.path.join(allocator, &.{ cwd, "template" });
    const addon_path = try std.fs.path.join(allocator, &.{ cwd, "addon" });

    Io.Dir.createDir(.cwd(), io, server_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    Io.Dir.createDir(.cwd(), io, dump_base_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const worlds_path = try std.fs.path.join(allocator, &.{ server_path, "worlds" });
    Io.Dir.createDir(.cwd(), io, worlds_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const target = try cli.resolveTargetVersion(allocator, io, opts);
    const target_version = target.version;

    const dump_path = try std.fs.path.join(allocator, &.{ dump_base_path, target_version });
    Io.Dir.createDir(.cwd(), io, dump_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    try bds.ensureInstalled(allocator, io, server_path, worlds_path, target);

    const pd_world_path = try std.fs.path.join(allocator, &.{ worlds_path, "palette-dumper" });
    Io.Dir.createDir(.cwd(), io, pd_world_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    try bds.copyDirRecursive(allocator, io, template_path, pd_world_path);

    const dev_packs_path = try std.fs.path.join(allocator, &.{ server_path, "development_behavior_packs" });
    Io.Dir.createDir(.cwd(), io, dev_packs_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const pd_pack_path = try std.fs.path.join(allocator, &.{ dev_packs_path, "palette-dumper" });
    Io.Dir.createDir(.cwd(), io, pd_pack_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    try bds.copyDirRecursive(allocator, io, addon_path, pd_pack_path);

    const config_path = try std.fs.path.join(allocator, &.{ server_path, "test_config.json" });
    try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = config_path, .data = "{\"generate_documentation\": true}" });

    const sp_path = try std.fs.path.join(allocator, &.{ server_path, "server.properties" });
    try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = sp_path, .data = "level-name=palette-dumper\n" });

    const perm_path = try std.fs.path.join(allocator, &.{ server_path, "config", "default", "permissions.json" });
    try bds.patchPermissions(allocator, io, perm_path);

    // Phase 1: Run BDS to generate documentation
    std.debug.print("Running BDS Phase 1: generating docs...\n", .{});
    bds.killStaleBds(io);
    {
        const bds_exe_path = try std.fs.path.join(allocator, &.{ server_path, bds.exeName() });
        var child = try std.process.spawn(io, .{
            .argv = &.{bds_exe_path},
            .cwd = .{ .path = server_path },
            .stdin = .ignore,
        });
        _ = try child.wait(io);
    }
    std.debug.print("Phase 1 complete.\n", .{});

    // Parse generated docs and derive block/permutation data
    const docs_path = try std.fs.path.join(allocator, &.{ server_path, "docs", "vanilladata_modules", "mojang-blocks.json" });
    const docs_raw = try bds.readFileAlloc(io, allocator, docs_path);
    var data = try dump.buildGameData(allocator, docs_raw);
    defer data.deinit(allocator);

    // Delete test_config.json
    Io.Dir.deleteFile(.cwd(), io, config_path) catch {};

    // Phase 1 modified the world; reset it from the template so Phase 2
    // loads the editor project cleanly instead of hanging on a dirty world.
    std.debug.print("Resetting world for Phase 2...\n", .{});
    try bds.removeDirRecursive(allocator, io, pd_world_path);
    Io.Dir.createDir(.cwd(), io, pd_world_path, .default_dir) catch {};
    try bds.copyDirRecursive(allocator, io, template_path, pd_world_path);

    // Phase 2: Restart BDS and collect addon data over HTTP
    std.debug.print("Running BDS Phase 2...\n", .{});
    const bds_exe_path = try std.fs.path.join(allocator, &.{ server_path, bds.exeName() });
    var child2 = try std.process.spawn(io, .{
        .argv = &.{bds_exe_path},
        .cwd = .{ .path = server_path },
        .stdin = .ignore,
    });
    defer child2.kill(io);

    var addon_parsed = try http.receiveAddonData(allocator, io);
    defer addon_parsed.deinit();

    try dump.writeDumps(allocator, io, dump_path, &data, addon_parsed.value);
    std.debug.print("Done! Data dumped to {s}/\n", .{dump_path});

    try r12.run(allocator, io, cwd, dump_path, data.block_states, data.block_types, data.permutations);
}
