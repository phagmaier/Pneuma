const std = @import("std");
const builtin = @import("builtin");
const Scheduler = @import("scheduler.zig").Scheduler;
const HarvestOutcome = @import("scheduler.zig").HarvestOutcome;
const ExperimentConfig = @import("scheduler.zig").ExperimentConfig;
const Stage4InjectionMode = @import("scheduler.zig").Stage4InjectionMode;
const Stage4ReseedPolicy = @import("scheduler.zig").Stage4ReseedPolicy;
const Lineage = @import("cpu.zig").Lineage;

fn lineageLabel(lineage: Lineage) []const u8 {
    return switch (lineage) {
        .default_ancestor => "dflt",
        .stage3_immigrant => "stg3",
        .stage4_immigrant => "stg4",
    };
}

fn outcomeLabel(outcome: HarvestOutcome) []const u8 {
    return switch (outcome) {
        .none => "none",
        .partial => "part",
        .full => "full",
    };
}

fn injectionModeLabel(mode: Stage4InjectionMode, tick: u32) []const u8 {
    _ = tick;
    return switch (mode) {
        .on_stage4_transition => "transition",
        .at_tick => "tick",
    };
}

fn reseedPolicyLabel(policy: Stage4ReseedPolicy) []const u8 {
    return switch (policy) {
        .stage3 => "stage3",
        .stage4 => "stage4",
    };
}

fn parseInjectionMode(arg: []const u8) !struct { mode: Stage4InjectionMode, tick: u32 } {
    if (std.mem.eql(u8, arg, "transition")) {
        return .{ .mode = .on_stage4_transition, .tick = 90_000 };
    }
    return .{
        .mode = .at_tick,
        .tick = try std.fmt.parseInt(u32, arg, 10),
    };
}

fn parseReseedPolicy(arg: []const u8) !Stage4ReseedPolicy {
    if (std.mem.eql(u8, arg, "stage3")) return .stage3;
    if (std.mem.eql(u8, arg, "stage4")) return .stage4;
    return error.InvalidStage4ReseedPolicy;
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    const maxTicks: ?u32 = blk: {
        const arg = args.next() orelse break :blk null;
        const val = std.fmt.parseInt(u32, arg, 10) catch break :blk null;
        break :blk if (val == 0) null else val;
    };
    const forcedSeed: ?u64 = blk: {
        const arg = args.next() orelse break :blk null;
        break :blk std.fmt.parseInt(u64, arg, 10) catch null;
    };
    var config = ExperimentConfig{};
    if (args.next()) |arg| {
        const injection = try parseInjectionMode(arg);
        config.stage4_injection_mode = injection.mode;
        config.stage4_injection_tick = injection.tick;
    }
    if (args.next()) |arg| {
        config.stage4_immigrant_energy = try std.fmt.parseInt(u32, arg, 10);
    }
    if (args.next()) |arg| {
        config.stage4_low_pop_reseed_policy = try parseReseedPolicy(arg);
    }

    var da = std.heap.DebugAllocator(.{}){};
    const allocator = if (builtin.mode == .Debug)
        da.allocator()
    else
        std.heap.smp_allocator;

    defer if (builtin.mode == .Debug) {
        _ = da.deinit();
    };

    const seed = forcedSeed orelse blk: {
        var random_seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&random_seed));
        break :blk random_seed;
    };
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();

    var scheduler = try Scheduler.init(allocator, rand, config);
    defer scheduler.deinit();

    // Seed: place 5 copies of the self-replicating ancestor
    try scheduler.loadAncestor(100, 3000);
    try scheduler.loadAncestor(1000, 3000);
    try scheduler.loadAncestor(2000, 3000);
    try scheduler.loadAncestor(4000, 3000);
    try scheduler.loadAncestor(8000, 3000);

    const print = std.debug.print;
    print(
        "=== Pneuma started seed={d} stage4_inject={s}",
        .{ seed, injectionModeLabel(config.stage4_injection_mode, config.stage4_injection_tick) },
    );
    if (config.stage4_injection_mode == .at_tick) {
        print(":{d}", .{config.stage4_injection_tick});
    }
    print(" stage4_energy={d} stage4_reseed={s} ===\n", .{
        config.stage4_immigrant_energy,
        reseedPolicyLabel(config.stage4_low_pop_reseed_policy),
    });

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
            const census = scheduler.lineageCensus();

            print("t={d:<6} pop={d:<3} avgE={d:<5} avgSz={d:<4} szRange=[{d},{d}] terr={d:<5} maxAge={d:<5} harv={d:<2} ph={d:<2} repl={d:<2}", .{
                scheduler.tick,
                n,
                avgE,
                avgS,
                minSize,
                maxSize,
                totalSize,
                maxAge,
                numHarvested,
                s.partial_harvests,
                numReplicating,
            });
            print(" | births={d} deaths={d} harvests={d} partials={d} reseeds={d} low={d} i3={d} i4={d} hTry={d} missT={d} tgt={d} miss2={d} s2={d} miss3={d} s3={d}", .{
                s.births,
                s.deaths,
                s.harvests,
                s.partial_harvests,
                s.reseeds,
                s.low_pop_reseeds,
                s.stage3_immigrant_injections,
                s.stage4_immigrant_injections,
                s.harvest_attempts,
                s.harvest_target_misses,
                s.harvest_target_hits,
                s.harvest_stage2_misses,
                s.harvest_stage2_hits,
                s.harvest_stage3_misses,
                s.harvest_stage3_hits,
            });
            print(" miss4r={d} s4r={d} missTr=[{d},{d},{d}] s4f={d} st={d} tw={d} challenge={d}->{d} stage={d} recipe={d}", .{
                s.harvest_stage4_reg_misses,
                s.harvest_stage4_reg_hits,
                s.harvest_stage4_trace0_misses,
                s.harvest_stage4_trace1_misses,
                s.harvest_stage4_trace2_misses,
                s.harvest_stage4_full_hits,
                s.store_ops,
                s.trace_writes,
                scheduler.challengeInput,
                scheduler.challengeTarget,
                scheduler.challengeStage,
                scheduler.challengeRecipeCode(),
            });
            print(" lineages=[{d},{d},{d}] harvestedBy=[{d},{d},{d}] replBy=[{d},{d},{d}] own={d} reserved={d} orphan={d} frag={d}\n", .{
                census.population.default_ancestor,
                census.population.stage3_immigrant,
                census.population.stage4_immigrant,
                census.harvested.default_ancestor,
                census.harvested.stage3_immigrant,
                census.harvested.stage4_immigrant,
                census.replicating.default_ancestor,
                census.replicating.stage3_immigrant,
                census.replicating.stage4_immigrant,
                diag.owned_cells,
                diag.reserved_child_cells,
                diag.orphaned_cells,
                diag.fragmented_cpus,
            });

            for (s.harvest_events[0..s.harvest_event_count]) |maybe_event| {
                if (maybe_event) |event| {
                    print("  event t={d} cpu={d} lin={s} stage={d} out={s} age={d} size={d} e={d} re={d} regs=[{d},{d},{d}] trace=[{d},{d},{d}] want=[{d},{d},{d},{d}]\n", .{
                        event.tick,
                        event.cpu_id,
                        lineageLabel(event.lineage),
                        event.stage,
                        outcomeLabel(event.outcome),
                        event.age,
                        event.size,
                        event.energy,
                        event.repro_energy,
                        event.ax,
                        event.bx,
                        event.cx,
                        event.trace0,
                        event.trace1,
                        event.trace2,
                        event.input,
                        event.witness1,
                        event.witness2,
                        event.target,
                    });
                }
            }

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
                print("  [{d}] id={d} lin={s} age={d} energy={d} size={d} start={d}", .{ i, cpu.id, lineageLabel(cpu.lineage), cpu.age, cpu.energy, cpu.size, cpu.start });
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
                            "cp", "ld", "st",
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
        print("Stopped at tick {d} due to maxTicks={d}\n", .{ scheduler.tick, limit });
    }
}
