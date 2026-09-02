const std = @import("std");
const builtin = @import("builtin");
const pg = @import("pg");
const stdx = @import("stdx");
const AuthServer = @import("./AuthServer.zig").AuthServer;
const ServerState = @import("./ServerState.zig").ServerState;
const WorldServer = @import("./WorldServer.zig").WorldServer;

const world = @import("world");
const WorldSimulation = world.WorldSimulation;
const default_db_url = "postgresql://arenacraft:arenacraft@127.0.0.1:5432/arenacraft";

pub fn main(init: std.process.Init) !void {
    const allocator = runtimeAllocator(init.gpa);
    defer detectRuntimeLeaks();
    stdx.ArcRuntime.setAllocator(allocator);

    const io = init.io;

    const database_url = init.environ_map.get("DATABASE_URL") orelse default_db_url;

    const pool = try pg.Pool.initUri(io, allocator, (try std.Uri.parse(database_url)), .{
        .size = 3,
        .timeout = 10_000,
    });
    defer pool.deinit();

    var state = ServerState.init(allocator);
    defer state.deinit();

    try state.populate(pool);

    var clock = stdx.Clock.init(io);

    var auth_server = try AuthServer.init(io, allocator, pool, &state, &clock);

    var world_sim = WorldSimulation.init(allocator, &clock);
    defer world_sim.deinit();

    var world_server = WorldServer.init(io, allocator, pool, &state, &world_sim, &clock);

    var root_fibers: std.Io.Group = .init;

    try root_fibers.concurrent(io, AuthServer.run, .{&auth_server});
    try root_fibers.concurrent(io, WorldServer.run, .{&world_server});
    try root_fibers.concurrent(io, WorldSimulation.run, .{ &world_sim, io });

    try root_fibers.concurrent(io, stdx.Clock.run, .{ &clock, io });

    var shutdown_signal = stdx.ShutdownSignal{};

    shutdown_signal.installSignalHandlers();
    while (!shutdown_signal.isShutdown()) {
        try io.sleep(.fromMilliseconds(100), .awake);
    }

    root_fibers.cancel(io);
}

const DebugAllocator = if (builtin.mode == .Debug)
    std.heap.DebugAllocator(.{})
else
    void;

var debug_allocator: DebugAllocator = if (builtin.mode == .Debug) .init else {};

fn runtimeAllocator(default_allocator: std.mem.Allocator) std.mem.Allocator {
    if (builtin.mode == .Debug) {
        debug_allocator.backing_allocator = default_allocator;
        return debug_allocator.allocator();
    }

    return default_allocator;
}

fn detectRuntimeLeaks() void {
    if (builtin.mode == .Debug) {
        const leaks = debug_allocator.detectLeaks();
        if (leaks != 0) {
            std.log.err("detected {d} allocator leak(s) at shutdown", .{leaks});
        }
        debug_allocator.deinitWithoutLeakChecks();
    }
}
