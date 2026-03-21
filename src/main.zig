const std = @import("std");
const builtin = @import("builtin");
const Scheduler = @import("scheduler.zig").Scheduler;
const Cpu = @import("cpu.zig").Cpu;

pub fn main() !void {
    const maxTicks: ?u32 = blk: {
        var args = std.process.args();
        _ = args.next();
        const arg = args.next() orelse break :blk null;
        const val = std.fmt.parseInt(u32, arg, 10) catch break :blk null;
        break :blk if (val == 0) null else val;
    };

    var da = std.heap.DebugAllocator(.{}){};
    const allocator = if (builtin.mode == .Debug)
        da.allocator()
    else
        std.heap.smp_allocator;

    defer if (builtin.mode == .Debug) {
        _ = da.deinit();
    };

    var prng: std.Random.DefaultPrng = .init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    var scheduler = try Scheduler.init(allocator, rand);
    defer scheduler.deinit();

    // Seed: place 5 copies of the self-replicating ancestor
    try scheduler.loadAncestor(100, 3000);
    try scheduler.loadAncestor(1000, 3000);
    try scheduler.loadAncestor(2000, 3000);
    try scheduler.loadAncestor(4000, 3000);
    try scheduler.loadAncestor(8000, 3000);

    const print = std.debug.print;
    print("=== Pneuma started ===\n", .{});

    // Tick loop
    while (scheduler.cpus.items.len > 0 and (maxTicks == null or scheduler.tick < maxTicks.?)) {
        try scheduler.doTick();

        // Log every 500 ticks
        if (@mod(scheduler.tick, 500) == 0) {
            const cpus = scheduler.cpus.items;
            const n = cpus.len;
            if (n == 0) break;

            var totalEnergy: u64 = 0;
            var totalSize: u64 = 0;
            var maxAge: u32 = 0;
            var minSize: u32 = std.math.maxInt(u32);
            var maxSize: u32 = 0;
            var numHarvested: u32 = 0;
            var numReplicating: u32 = 0; // organisms with childSize > 0 (in middle of MAL/copy)

            for (cpus) |cpu| {
                totalEnergy += cpu.energy;
                totalSize += cpu.size;
                if (cpu.age > maxAge) maxAge = cpu.age;
                if (cpu.size < minSize) minSize = cpu.size;
                if (cpu.size > maxSize) maxSize = cpu.size;
                if (cpu.harvested) numHarvested += 1;
                if (cpu.childSize > 0) numReplicating += 1;
            }

            const avgE = totalEnergy / n;
            const avgS = totalSize / n;
            const s = &scheduler.stats;
            const diag = scheduler.diagnostics();

            print("t={d:<6} pop={d:<3} avgE={d:<5} avgSz={d:<4} szRange=[{d},{d}] terr={d:<5} maxAge={d:<5} harv={d:<2} repl={d:<2} | births={d} deaths={d} harvests={d} reseeds={d} target={d} own={d} reserved={d} orphan={d} frag={d}\n", .{
                scheduler.tick,
                n,
                avgE,
                avgS,
                minSize,
                maxSize,
                totalSize,
                maxAge,
                numHarvested,
                numReplicating,
                s.births,
                s.deaths,
                s.harvests,
                s.reseeds,
                scheduler.challengeTarget,
                diag.owned_cells,
                diag.reserved_child_cells,
                diag.orphaned_cells,
                diag.fragmented_cpus,
            });

            s.reset();
        }

        // Detailed genome dump every 10000 ticks
        if (@mod(scheduler.tick, 10000) == 0) {
            const diag = scheduler.diagnostics();
            print("\n--- Genome snapshot at tick {d} ---\n", .{scheduler.tick});
            print("diag: own={d} contiguous={d} reserved={d} orphan={d} fragmented={d}\n", .{
                diag.owned_cells,
                diag.contiguous_cells,
                diag.reserved_child_cells,
                diag.orphaned_cells,
                diag.fragmented_cpus,
            });
            const cpus = scheduler.cpus.items;
            const maxDump = @min(cpus.len, 5); // dump up to 5 organisms
            for (cpus[0..maxDump], 0..) |cpu, i| {
                print("  [{d}] id={d} age={d} energy={d} size={d} start={d}", .{ i, cpu.id, cpu.age, cpu.energy, cpu.size, cpu.start });
                if (cpu.childSize > 0) print(" child@{d}x{d}", .{ cpu.childStart, cpu.childSize });
                print("\n       code: ", .{});
                const codeLen = @min(cpu.size, 60); // show first 60 instructions
                for (0..codeLen) |j| {
                    const addr = (cpu.start +% @as(u32, @intCast(j))) % 131_072;
                    const opVal = scheduler.soup.mem[addr];
                    if (opVal <= 33) {
                        const names = [_][]const u8{
                            "n0", "n1", "or", "sh", "zr", "iz", "sb", "sc",
                            "ia", "ib", "dc", "pA", "oA", "oB", "oC", "af",
                            "ab", "ca", "rt", "mB", "mD", "ml", "dv", "sn",
                            "pl", "ij", "mg", "hv", "ex", "sk", "rA", "aR",
                            "cp", "ld",
                        };
                        print("{s} ", .{names[opVal]});
                    } else {
                        print("?{d} ", .{opVal});
                    }
                }
                if (cpu.size > 60) print("...", .{});
                print("\n", .{});
            }
            print("---\n\n", .{});
        }
    }

    if (scheduler.cpus.items.len == 0) {
        print("All organisms dead at tick {d}\n", .{scheduler.tick});
    } else if (maxTicks) |limit| {
        print("Stopped at tick {d} due to maxTicks={d}\n", .{scheduler.tick, limit});
    }
}
