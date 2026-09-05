const std = @import("std");

var STDX_MOD: ?*std.Build.Module = null;
var STDX_TEST_STEP: *std.Build.Step = undefined;
var ECS_MOD: ?*std.Build.Module = null;
var PROTOCOL_MOD: ?*std.Build.Module = null;
var PROTOCOL_TEST_STEP: *std.Build.Step = undefined;
var DB_MOD: ?*std.Build.Module = null;
var DB_TEST_STEP: *std.Build.Step = undefined;
var DOMAIN_MOD: ?*std.Build.Module = null;
var DOMAIN_TEST_STEP: *std.Build.Step = undefined;
var GAME_DATA_MOD: ?*std.Build.Module = null;
var GAME_DATA_TEST_STEP: *std.Build.Step = undefined;
var SERVER_MOD: ?*std.Build.Module = null;
var SERVER_TEST_STEP: *std.Build.Step = undefined;
var WORLD_MOD: ?*std.Build.Module = null;
var WORLD_TEST_STEP: *std.Build.Step = undefined;
var OPTIONS: ?*std.Build.Step.Options = null;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    addOptions(b);
    try addStdx(b, target, optimize);
    try addEcs(b, target, optimize);
    try addDomain(b, target, optimize);
    try addGameData(b, target, optimize);
    try addProtocol(b, target, optimize);
    try addDb(b, target, optimize);
    try addWorld(b, target, optimize);
    try addServer(b, target, optimize);

    const all_test = b.step("all-test", "Run all module tests");
    all_test.dependOn(STDX_TEST_STEP);
    all_test.dependOn(DOMAIN_TEST_STEP);
    all_test.dependOn(GAME_DATA_TEST_STEP);
    all_test.dependOn(PROTOCOL_TEST_STEP);
    all_test.dependOn(DB_TEST_STEP);
    all_test.dependOn(WORLD_TEST_STEP);
    all_test.dependOn(SERVER_TEST_STEP);
}

/// Declares shared build options once and exposes them to every module via
/// `build_config`. Any module needing a build option should use this global
/// set rather than defining its own.
fn addOptions(b: *std.Build) void {
    const enable_verbose_packet_log = b.option(bool, "enable-verbose-packet-log", "Will display all packets and their byte representation, useful for debugging protocol correctness") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "enable-verbose-packet-log", enable_verbose_packet_log);
    OPTIONS = options;
}

fn addEcs(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    ECS_MOD = b.dependency("entt", .{
        .target = target,
        .optimize = optimize,
    }).module("zig-ecs");
}

fn addDomain(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const stdx_mod = STDX_MOD orelse return error.MissingModule;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/domain/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "stdx", .module = stdx_mod },
        },
    });
    DOMAIN_MOD = mod;

    const tst = b.addTest(.{ .root_module = mod });
    const run = b.addRunArtifact(tst);
    if (b.args) |args| {
        run.addArgs(args);
    }
    DOMAIN_TEST_STEP = b.step("domain-test", "Run domain tests");
    DOMAIN_TEST_STEP.dependOn(&run.step);
}

/// Declares the `game_data` module: parses the generated `game_data_db`
/// rows into lookups conforming to domain types.
fn addGameData(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const game_data_db_mod = try generateGameDataDbModule(b);
    const domain_mod = DOMAIN_MOD orelse return error.MissingModule;
    const stdx_mod = STDX_MOD orelse return error.MissingModule;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/game_data/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "game_data_db", .module = game_data_db_mod },
            .{ .name = "domain", .module = domain_mod },
            .{ .name = "stdx", .module = stdx_mod },
        },
    });
    GAME_DATA_MOD = mod;

    const tst = b.addTest(.{ .root_module = mod });
    const run = b.addRunArtifact(tst);
    if (b.args) |args| {
        run.addArgs(args);
    }
    GAME_DATA_TEST_STEP = b.step("game_data-test", "Run game_data tests");
    GAME_DATA_TEST_STEP.dependOn(&run.step);
}

/// Scans `src/game_data/db/*.zon` at configure time and emits a generated
/// `game_data_db` module. Each `foo.zon` holds a ZON array of homogeneous
/// object rows. ZON is a subset of Zig expression syntax, so the file
/// content is pasted verbatim into a generated `foo.zig` and the Zig
/// compiler itself derives the `Row` struct via comptime reflection (see
/// `src/game_data/db/zon_rows.zig`): ints become `i64`, floats `f64`,
/// bools `bool`, strings `[]const u8`. Rows must be homogeneous (same
/// fields in every row; write `1.0` for a float column). `build()` re-runs
/// on every `zig build`, so edits to the data files are picked up
/// automatically.
fn generateGameDataDbModule(b: *std.Build) !*std.Build.Module {
    const io = b.graph.io;
    const gpa = b.allocator;

    var data_dir = try b.build_root.handle.openDir(io, "src/game_data/db", .{ .iterate = true });
    defer data_dir.close(io);

    var stems: std.ArrayList([]const u8) = .empty;
    var it = data_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
        const stem = entry.name[0 .. entry.name.len - ".zon".len];
        try stems.append(gpa, try gpa.dupe(u8, stem));
    }

    std.mem.sort([]const u8, stems.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lessThan);

    const wf = b.addWriteFiles();
    _ = wf.add("zon_rows.zig", try data_dir.readFileAlloc(io, "zon_rows.zig", gpa, .limited(1 << 16)));

    var root_src: std.ArrayList(u8) = .empty;
    try root_src.appendSlice(gpa, "// GENERATED by build.zig from src/game_data/db/*.zon - DO NOT EDIT.\n");

    for (stems.items) |stem| {
        const zon_bytes = try data_dir.readFileAlloc(io, b.fmt("{s}.zon", .{stem}), gpa, .limited(1 << 22));
        _ = wf.add(b.fmt("{s}.zig", .{stem}), try generateGameDataFile(gpa, zon_bytes));
        try root_src.appendSlice(gpa, b.fmt("pub const {s} = @import(\"{s}.zig\");\n", .{ stem, stem }));
    }

    const root = wf.add("game_data.zig", root_src.items);
    return b.createModule(.{ .root_source_file = root });
}

fn generateGameDataFile(gpa: std.mem.Allocator, zon_bytes: []const u8) ![]const u8 {
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(gpa, "// GENERATED from a src/game_data/db/*.zon file by build.zig - DO NOT EDIT.\n");
    try src.appendSlice(gpa, "const zon_rows = @import(\"zon_rows.zig\");\n\nconst raw = ");
    try src.appendSlice(gpa, zon_bytes);
    try src.appendSlice(gpa, ";\n\npub const Row = zon_rows.Row(raw);\n");
    try src.appendSlice(gpa, "pub const rows: []const Row = zon_rows.materialize(Row, raw);\n");
    return src.items;
}

fn addDb(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const pg_mod = b.dependency("pg", .{ .target = target, .optimize = optimize }).module("pg");
    const domain_mod = DOMAIN_MOD orelse return error.MissingModule;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/db/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pg", .module = pg_mod },
            .{ .name = "domain", .module = domain_mod },
        },
    });
    DB_MOD = mod;

    const tst = b.addTest(.{ .root_module = mod });
    const run = b.addRunArtifact(tst);
    if (b.args) |args| {
        run.addArgs(args);
    }
    DB_TEST_STEP = b.step("db-test", "Run db tests");
    DB_TEST_STEP.dependOn(&run.step);
}

fn addWorld(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const stdx_mod = STDX_MOD orelse return error.MissingModule;
    const ecs_mod = ECS_MOD orelse return error.MissingModule;
    const domain_mod = DOMAIN_MOD orelse return error.MissingModule;
    const game_data_mod = GAME_DATA_MOD orelse return error.MissingModule;
    const protocol_mod = PROTOCOL_MOD orelse return error.MissingModule;
    const options = OPTIONS orelse return error.MissingModule;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/world/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "stdx", .module = stdx_mod },
            .{ .name = "ecs", .module = ecs_mod },
            .{ .name = "domain", .module = domain_mod },
            .{ .name = "game_data", .module = game_data_mod },
            .{ .name = "protocol", .module = protocol_mod },
        },
    });
    mod.addOptions("build_config", options);
    WORLD_MOD = mod;
    const tst = b.addTest(.{
        .root_module = mod,
    });
    const run = b.addRunArtifact(tst);
    if (b.args) |args| {
        run.addArgs(args);
    }
    WORLD_TEST_STEP = b.step("world-test", "Run world tests");
    WORLD_TEST_STEP.dependOn(&run.step);
}

fn addStdx(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/stdx/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    STDX_MOD = mod;
    const tst = b.addTest(.{
        .root_module = mod,
    });
    const run = b.addRunArtifact(tst);
    if (b.args) |args| {
        run.addArgs(args);
    }
    STDX_TEST_STEP = b.step("stdx-test", "Run stdx tests");
    STDX_TEST_STEP.dependOn(&run.step);
}

fn addProtocol(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const domain_mod = DOMAIN_MOD orelse return error.MissingModule;
    const game_data_mod = GAME_DATA_MOD orelse return error.MissingModule;
    const stdx_mod = STDX_MOD orelse return error.MissingModule;
    const options = OPTIONS orelse return error.MissingModule;
    const mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/Protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain", .module = domain_mod },
            .{ .name = "game_data", .module = game_data_mod },
            .{ .name = "stdx", .module = stdx_mod },
        },
    });
    mod.addOptions("build_config", options);
    PROTOCOL_MOD = mod;
    const tst = b.addTest(.{
        .root_module = mod,
    });
    const run = b.addRunArtifact(tst);
    if (b.args) |args| {
        run.addArgs(args);
    }
    PROTOCOL_TEST_STEP = b.step("protocol-test", "Run protocol tests");
    PROTOCOL_TEST_STEP.dependOn(&run.step);
}

fn addServer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const stdx_mod = STDX_MOD orelse return error.MissingModule;
    const protocol_mod = PROTOCOL_MOD orelse return error.MissingModule;
    const db_mod = DB_MOD orelse return error.MissingModule;
    const domain_mod = DOMAIN_MOD orelse return error.MissingModule;
    const game_data_mod = GAME_DATA_MOD orelse return error.MissingModule;
    const world_mod = WORLD_MOD orelse return error.MissingModule;
    const pg_mod = b.dependency("pg", .{ .target = target, .optimize = optimize }).module("pg");
    const options = OPTIONS orelse return error.MissingModule;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "stdx", .module = stdx_mod },
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "db", .module = db_mod },
            .{ .name = "domain", .module = domain_mod },
            .{ .name = "game_data", .module = game_data_mod },
            .{ .name = "world", .module = world_mod },
            .{ .name = "pg", .module = pg_mod },
        },
    });
    mod.addOptions("build_config", options);

    SERVER_MOD = mod;
    const exe = b.addExecutable(.{
        .name = "arenacraft2",
        .root_module = mod,
    });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step); // plain `zig build`
    const build_step = b.step("server-build", "Build and install server");
    build_step.dependOn(&install.step);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    if (b.args) |args| {
        run.addArgs(args);
    }
    const run_step = b.step("server-run", "Run server");
    run_step.dependOn(&run.step);
    const tst = b.addTest(.{
        .root_module = mod,
    });
    const test_run = b.addRunArtifact(tst);
    if (b.args) |args| {
        test_run.addArgs(args);
    }
    SERVER_TEST_STEP = b.step("server-test", "Run server tests");
    SERVER_TEST_STEP.dependOn(&test_run.step);
}
