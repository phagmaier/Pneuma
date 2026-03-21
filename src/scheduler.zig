const std = @import("std");
const Op = @import("op.zig").Op;
const Soup = @import("soup.zig").Soup;
const cpu_mod = @import("cpu.zig");
const Cpu = cpu_mod.Cpu;
const SIZE = Soup.SIZE;
const MAXENERGY = cpu_mod.MAXENERGY;
const T_CHALLENGE: u32 = 1500;
const E_HARVEST: u32 = 500;
const PASSIVE_DEPOSITS: u32 = 4000;
const EPOCH2_START: u32 = 10_000;
const EPOCH3_START: u32 = 50_000;
const CHALLENGE_ADDR: u32 = 0;
const MAX_CHALLENGE_OPS: usize = 5;

const Challenge = struct {
    input: u32,
    target: u32,
};

const ChallengeOp = enum(u8) {
    inc,
    dec,
    shl,
    or1,
};

const ChallengeRecipe = struct {
    ops: [MAX_CHALLENGE_OPS]ChallengeOp,
    count: u8,
    input_max: u32,
};

pub const Stats = struct {
    births: u32 = 0,
    deaths: u32 = 0,
    harvests: u32 = 0,
    reseeds: u32 = 0,

    pub fn reset(self: *Stats) void {
        self.births = 0;
        self.deaths = 0;
        self.harvests = 0;
        self.reseeds = 0;
    }
};

pub const Diagnostics = struct {
    owned_cells: u32 = 0,
    contiguous_cells: u32 = 0,
    reserved_child_cells: u32 = 0,
    orphaned_cells: u32 = 0,
    fragmented_cpus: u32 = 0,
};

pub const Scheduler = struct {
    tick: u32,
    nextId: u32,
    challengeStage: u8,
    challengeInput: u32,
    challengeTarget: u32,
    challengeRecipe: ChallengeRecipe,
    challengeTimer: u32,
    allocator: std.mem.Allocator,
    rand: std.Random,
    cpus: std.ArrayList(Cpu),
    soup: Soup,
    stats: Stats,

    pub fn init(allocator: std.mem.Allocator, rand: std.Random) !Scheduler {
        var sched = Scheduler{
            .tick = 0,
            .nextId = 0,
            .challengeStage = 1,
            .challengeInput = 0,
            .challengeTarget = 0,
            .challengeRecipe = undefined,
            .challengeTimer = 0,
            .allocator = allocator,
            .rand = rand,
            .cpus = std.ArrayList(Cpu).empty,
            .soup = try Soup.init(allocator),
            .stats = .{},
        };
        sched.challengeStage = stageForTick(sched.tick);
        sched.challengeRecipe = generateRecipe(sched.challengeStage, rand);
        const challenge = generateChallenge(sched.challengeRecipe, rand);
        sched.challengeInput = challenge.input;
        sched.challengeTarget = challenge.target;
        sched.soup.mem[CHALLENGE_ADDR] = challenge.input;
        return sched;
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.cpus.items) |*cpu| {
            cpu.deinit(self.allocator);
        }
        self.cpus.deinit(self.allocator);
        self.soup.deinit(self.allocator);
    }

    pub fn spawnOrganism(self: *Scheduler, start: u32, size: u32, energy: u32) !void {
        const region = self.soup.findFree(start, size, size) orelse return error.RegionOccupied;
        if (region != Soup.wrap(start)) return error.RegionOccupied;
        const id = self.nextId;
        self.nextId += 1;
        var cpu = try Cpu.init(self.allocator, id, region, size);
        cpu.energy = energy;
        self.soup._claim(id, region, size);
        try self.cpus.append(self.allocator, cpu);
    }

    fn findCpuIndexById(self: *Scheduler, id: u32) ?usize {
        for (self.cpus.items, 0..) |cpu, idx| {
            if (cpu.id == id) return idx;
        }
        return null;
    }

    fn cullZeroEnergy(self: *Scheduler, current_id: u32) ?usize {
        var current_alive = true;
        var idx: usize = 0;
        while (idx < self.cpus.items.len) {
            if (self.cpus.items[idx].energy == 0) {
                if (self.cpus.items[idx].id == current_id) current_alive = false;
                self.kill(idx);
                continue;
            }
            idx += 1;
        }
        if (!current_alive) return null;
        return self.findCpuIndexById(current_id);
    }

    fn getOp(_idx: u32, soup: *const Soup) Op {
        const idx = soup.getOp(_idx);
        return Op.toOp(idx);
    }

    fn reg(cpu: *const Cpu, idx: u8) u32 {
        return if (idx < cpu.registers.len) cpu.registers[idx] else 0;
    }

    fn setReg(cpu: *Cpu, idx: u8, val: u32) void {
        if (idx < cpu.registers.len) cpu.registers[idx] = val;
    }

    pub fn execute(cpus: []Cpu, cpu: *Cpu, soup: *Soup, allocator: std.mem.Allocator, rand: std.Random, challengeTarget: u32, stats: *Stats) !bool {
        const AX: u8 = 0;
        const BX: u8 = 1;
        const CX: u8 = 2;

        cpu.cost = 1;
        if (cpu.registers.len == 0) {
            cpu.inc(SIZE);
            return false;
        }
        var advance_ip = true;
        const op = getOp(cpu.ip, soup);
        switch (op) {
            .nop0, .nop1 => {},
            .or1 => cpu.registers[AX] |= 1,
            .shl => cpu.registers[AX] = std.math.shl(u32, cpu.registers[0], 1),
            .zero => cpu.registers[AX] = 0,
            .ifCZ => if (reg(cpu, CX) != 0) cpu.inc(SIZE),
            .subAB => setReg(cpu, CX, reg(cpu, AX) -| reg(cpu, BX)),
            .subAC => cpu.registers[AX] = cpu.registers[AX] -| reg(cpu, CX),
            .incA => cpu.registers[AX] = cpu.registers[AX] +| 1,
            .incB => setReg(cpu, BX, reg(cpu, BX) +| 1),
            .decC => setReg(cpu, CX, reg(cpu, CX) -| 1),
            .pushA => {
                _ = cpu.push(cpu.registers[AX]);
            },
            .popA => {
                if (cpu.pop()) |num| {
                    cpu.registers[AX] = num;
                }
            },
            .popB => {
                if (cpu.pop()) |num| {
                    setReg(cpu, BX, num);
                }
            },
            .popC => {
                if (cpu.pop()) |num| {
                    setReg(cpu, CX, num);
                }
            },
            .adrf => {
                const result = try soup.search(Soup.incWrap(cpu.ip), Soup.incWrap(cpu.ip), allocator, false);
                if (result) |addr| {
                    cpu.registers[AX] = addr;
                }
            },
            .adrb => {
                const result = try soup.search(Soup.incWrap(cpu.ip), Soup.subWrap(cpu.ip), allocator, true);
                if (result) |addr| {
                    cpu.registers[AX] = addr;
                }
            },
            .call => {
                _ = cpu.push(Soup.incWrap(cpu.ip));
                cpu.ip = cpu.registers[AX];
                advance_ip = false;
            },
            .ret => {
                if (cpu.pop()) |addr| {
                    cpu.ip = Soup.wrap(addr);
                }
                advance_ip = false;
            },
            .movAB => cpu.registers[AX] = reg(cpu, BX),
            .movCD => setReg(cpu, CX, if (cpu.registers.len < 4) 0 else cpu.registers[3]),

            .mal => {
                const cpySize = reg(cpu, CX);
                if (cpu.childSize == 0 and cpySize > 0 and cpySize <= cpu.size) {
                    const searchSize = cpu.size * 20;
                    const result = soup.claim(Soup.wrap(cpu.start + cpu.size), cpySize, cpu.id, searchSize);
                    if (result) |start| {
                        cpu.childStart = start;
                        cpu.childSize = cpySize;
                        cpu.registers[AX] = start;
                    }
                }
            },
            .div => {
                if (cpu.childSize > 0) {
                    cpu.cost = 5;
                    cpu.inc(SIZE);
                    return true;
                }
            },

            .scan => {
                cpu.cost = 3;
                const result = try soup.scanSearch(cpu.ip, allocator);
                if (result) |addr| {
                    cpu.registers[AX] = addr;
                } else {
                    cpu.registers[AX] = std.math.maxInt(u32);
                }
            },
            .pull => cpu.pull(soup.mem, soup.occupied, cpus, rand),
            .inject => cpu.inject(soup.mem),
            .merge => cpu.merge(soup.occupied, soup.scavenge),
            .harvest => {
                if (cpu.registers[AX] == challengeTarget and !cpu.harvested) {
                    cpu.energy = @min(cpu.energy + E_HARVEST, MAXENERGY);
                    cpu.harvested = true;
                    stats.harvests += 1;
                }
            },
            .extend => {
                if (cpu.registers.len > 0) {
                    switch (cpu.registers[AX]) {
                        0 => {
                            if (cpu.registers.len < 8 and cpu.energy >= 50) {
                                try cpu.growRegisters(allocator);
                                cpu.cost = 50;
                            }
                        },
                        1 => {
                            if (cpu.stack.len < 64 and cpu.energy >= 50) {
                                try cpu.growStack(allocator);
                                cpu.cost = 50;
                            }
                        },
                        else => {},
                    }
                }
            },

            .shrink => {
                if (cpu.registers.len > 0) {
                    switch (cpu.registers[AX]) {
                        0 => try cpu.shrinkRegisters(allocator),
                        1 => try cpu.shrinkStack(allocator),
                        else => {},
                    }
                }
            },

            .movRA => {
                const size = @as(u32, @intCast(cpu.registers.len));
                if (size == 0) return false;
                const idx = @mod(reg(cpu, CX), size);
                cpu.registers[AX] = cpu.registers[idx];
            },
            .movAR => {
                const size = @as(u32, @intCast(cpu.registers.len));
                if (size == 0) return false;
                const idx = @mod(reg(cpu, CX), size);
                cpu.registers[idx] = cpu.registers[AX];
            },
            .copy => {
                const src = Soup.wrap(reg(cpu, BX));
                const value = soup.mem[src];
                const mr = cpu_mod.mutate(value, rand);
                if (!mr.skip) {
                    var dst = Soup.wrap(cpu.registers[AX]);
                    if (mr.insert_before) |ins| {
                        if (dst != 0) soup.mem[dst] = ins;
                        dst = Soup.incWrap(dst);
                    }
                    if (dst != 0) soup.mem[dst] = mr.value;
                }
            },
            .load => {
                // AX = mem[AX] — read soup memory into register
                cpu.registers[AX] = soup.mem[Soup.wrap(cpu.registers[AX])];
            },
        }
        if (advance_ip) cpu.inc(SIZE);
        return false;
    }

    fn kill(self: *Scheduler, idx: usize) void {
        self.stats.deaths += 1;
        var cpu = self.cpus.items[idx];

        // 1. Deposit 50% of remaining energy as scavenge across owned addresses
        if (cpu.energy > 0 and cpu.size > 0) {
            const deposit = cpu.energy / 2;
            const perAddr = deposit / cpu.size;
            const remainder = deposit % cpu.size;
            for (0..cpu.size) |i| {
                const addr = Soup.wrap(cpu.start + @as(u32, @intCast(i)));
                self.soup.scavenge[addr] += perAddr;
                if (i < remainder) {
                    self.soup.scavenge[addr] += 1;
                }
            }
        }

        // 2. Free ownership (leave instruction data — fossil layer)
        self.soup.free(cpu.start, cpu.size);
        if (cpu.childSize > 0) {
            self.soup.free(cpu.childStart, cpu.childSize);
        }

        // 3. Deallocate CPU resources and remove from list
        cpu.deinit(self.allocator);
        _ = self.cpus.swapRemove(idx);
    }

    fn spawnChild(self: *Scheduler, parent: *Cpu, newborns: *std.ArrayList(Cpu)) !void {
        self.stats.births += 1;
        const childId = self.nextId;
        self.nextId += 1;
        self.soup._claim(childId, parent.childStart, parent.childSize);

        // Energy split: child gets half, parent keeps other half
        const childEnergy = parent.energy / 2;
        parent.energy -= childEnergy;
        // Reset parent age — reward for successful replication
        parent.age = 0;

        const child = try Cpu.initChild(
            self.allocator,
            childId,
            parent.childStart,
            parent.childSize,
            parent.registers.len,
            parent.stack.len,
            childEnergy,
        );
        try newborns.append(self.allocator, child);

        parent.childStart = 0;
        parent.childSize = 0;
    }

    fn shuffle(self: *Scheduler) void {
        const items = self.cpus.items;
        if (items.len <= 1) return;
        var i: usize = items.len - 1;
        while (i > 0) : (i -= 1) {
            const j = self.rand.intRangeAtMost(usize, 0, i);
            const tmp = items[i];
            items[i] = items[j];
            items[j] = tmp;
        }
    }

    pub fn diagnostics(self: *Scheduler) Diagnostics {
        var diag = Diagnostics{};
        for (self.soup.occupied) |owner| {
            if (owner != null) diag.owned_cells += 1;
        }
        for (self.cpus.items) |cpu| {
            var contiguous: u32 = 0;
            for (0..cpu.size) |i| {
                const addr = Soup.wrap(cpu.start + @as(u32, @intCast(i)));
                if (self.soup.occupied[addr] == cpu.id) {
                    contiguous += 1;
                }
            }
            diag.contiguous_cells += contiguous;
            if (contiguous != cpu.size) diag.fragmented_cpus += 1;
            diag.reserved_child_cells += cpu.childSize;
        }
        const accounted_cells = diag.contiguous_cells + diag.reserved_child_cells;
        if (diag.owned_cells > accounted_cells) {
            diag.orphaned_cells = diag.owned_cells - accounted_cells;
        }
        return diag;
    }

    pub fn challengeRecipeCode(self: *const Scheduler) u32 {
        var code: u32 = 0;
        for (0..self.challengeRecipe.count) |i| {
            code = code * 10 + @as(u32, @intFromEnum(self.challengeRecipe.ops[i])) + 1;
        }
        return code;
    }

    pub fn doTick(self: *Scheduler) !void {
        // 1. Shuffle execution order
        self.shuffle();

        // 2-6. Execute each organism, handle energy + death
        var newborns = std.ArrayList(Cpu).empty;
        defer newborns.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.cpus.items.len) {
            const current_id = self.cpus.items[i].id;
            var cpu = &self.cpus.items[i];

            // 2. Execute 1 instruction (sets cpu.cost)
            const divHappened = try execute(self.cpus.items, cpu, &self.soup, self.allocator, self.rand, self.challengeTarget, &self.stats);
            const current_idx = self.cullZeroEnergy(current_id) orelse continue;
            cpu = &self.cpus.items[current_idx];

            // Handle DIVIDE — spawn child before energy deduction
            if (divHappened) {
                try self.spawnChild(cpu, &newborns);
            }

            // 3. Deduct per-instruction energy cost
            if (cpu.energy <= cpu.cost) {
                self.kill(current_idx);
                continue;
            }
            cpu.energy -= cpu.cost;

            // 5. Deduct baseline (2) + hardware maintenance costs
            const maint = cpu.maintenanceCost();
            if (cpu.energy <= maint) {
                self.kill(current_idx);
                continue;
            }
            cpu.energy -= maint;

            cpu.age += 1;
            i = current_idx + 1;
        }

        // Add newborn children (they execute next tick)
        for (newborns.items) |child| {
            try self.cpus.append(self.allocator, child);
        }

        // 7. Deposit passive energy at random occupied addresses
        for (0..PASSIVE_DEPOSITS) |_| {
            const addr = self.rand.intRangeLessThan(u32, 0, SIZE);
            if (self.soup.occupied[addr]) |id| {
                for (self.cpus.items) |*cpu| {
                    if (cpu.id == id) {
                        cpu.energy = @min(cpu.energy + 1, MAXENERGY);
                        break;
                    }
                }
            }
        }

        // 8. Cosmic ray — flip 1 random instruction every 3 ticks
        if (@mod(self.tick, 3) == 0) {
            const cosmicAddr = self.rand.intRangeLessThan(u32, 1, SIZE);
            self.soup.mem[cosmicAddr] = Op.randOp(self.rand);
        }

        // 9. Challenge timer
        self.challengeTimer += 1;
        if (self.challengeTimer >= T_CHALLENGE) {
            self.challengeTimer = 0;
            const stage = stageForTick(self.tick);
            if (stage != self.challengeStage) {
                self.challengeStage = stage;
                self.challengeRecipe = generateRecipe(stage, self.rand);
            }
            const challenge = generateChallenge(self.challengeRecipe, self.rand);
            self.challengeInput = challenge.input;
            self.challengeTarget = challenge.target;
            self.soup.mem[CHALLENGE_ADDR] = challenge.input;
            for (self.cpus.items) |*cpu| {
                cpu.harvested = false;
            }
        }

        // 10. Re-seed if population is low (every 2000 ticks)
        if (@mod(self.tick, 2000) == 0 and self.cpus.items.len < 10) {
            const addr = self.rand.intRangeLessThan(u32, 1, SIZE);
            self.loadAncestor(addr, 3000) catch {};
            self.stats.reseeds += 1;
        }

        self.tick += 1;
    }

    pub fn loadAncestor(self: *Scheduler, addr: u32, energy: u32) !void {
        const n = Op.toNum;
        // 42-instruction self-replicating ancestor with epoch-1 harvest
        const program = [_]u32{
            // Start marker: nop1 nop1 nop0 nop0  (pos 0-3)
            n(.nop1),  n(.nop1),  n(.nop0),  n(.nop0),
            // Harvest: AX=0 → load challenge input → INC_A → harvest  (pos 4-7)
            n(.zero),
            n(.load),
            n(.incA),
            n(.harvest),
            // ADRB to find start marker
            n(.adrb),
            // Template: 1 1 0 0 (backward search matches start marker 1 1 0 0)
            n(.nop1),  n(.nop1),  n(.nop0),  n(.nop0),
            // Save start in stack, find end
            n(.pushA),
            n(.adrf),
            // Template: 1 1 0 0 (forward complement search matches end marker 0 0 1 1)
            n(.nop1),  n(.nop1),  n(.nop0),  n(.nop0),
            // BX=start, CX=length, allocate child
            n(.popB),
            n(.subAB),
            n(.mal),
            // Save child_start
            n(.pushA),
            // Copy loop marker: nop0 nop1
            n(.nop0),  n(.nop1),
            // Copy loop body: restore AX, discard CALL return addr
            n(.popA),
            n(.popA),
            // Copy one instruction with mutation
            n(.copy),
            // Advance pointers
            n(.incA),
            n(.incB),
            n(.decC),
            // If CX!=0 skip DIVIDE
            n(.ifCZ),
            // CX==0: spawn child
            n(.div),
            // Save AX, find copy loop, jump back
            n(.pushA),
            n(.adrb),
            // Template: 0 1 (backward search matches copy loop marker 0 1)
            n(.nop0),  n(.nop1),
            // CALL jumps to copy loop
            n(.call),
            // End marker: nop0 nop0 nop1 nop1
            n(.nop0),  n(.nop0),  n(.nop1),  n(.nop1),
        };

        const size: u32 = program.len;
        const start = self.soup.findFree(addr, size, SIZE - 1) orelse return error.NoSpaceForAncestor;
        // Write program into soup memory
        for (program, 0..) |inst, i| {
            const idx = Soup.wrap(start + @as(u32, @intCast(i)));
            self.soup.mem[idx] = inst;
        }
        // Spawn organism at this address
        try self.spawnOrganism(start, size, energy);
    }
};

fn applyChallengeOp(val: u32, op: ChallengeOp) u32 {
    return switch (op) {
        .inc => val +| 1,
        .dec => val -| 1,
        .shl => std.math.shl(u32, val, 1),
        .or1 => val | 1,
    };
}

fn stageForTick(tick: u32) u8 {
    if (tick < EPOCH2_START) return 1;
    if (tick < EPOCH3_START) return 2;
    return 3;
}

fn generateRecipe(stage: u8, rand: std.Random) ChallengeRecipe {
    _ = rand;
    var recipe = ChallengeRecipe{
        .ops = undefined,
        .count = 0,
        .input_max = 0,
    };
    switch (stage) {
        1 => {
            recipe.ops[0] = .inc;
            recipe.count = 1;
            recipe.input_max = 30;
        },
        2 => {
            recipe.ops[0] = .or1;
            recipe.count = 1;
            recipe.input_max = 15;
        },
        else => {
            recipe.ops[0] = .shl;
            recipe.ops[1] = .or1;
            recipe.input_max = 7;
            recipe.count = 2;
        },
    }
    return recipe;
}

fn generateChallenge(recipe: ChallengeRecipe, rand: std.Random) Challenge {
    const input = rand.intRangeAtMost(u32, 0, recipe.input_max);
    var val = input;
    for (0..recipe.count) |i| {
        val = applyChallengeOp(val, recipe.ops[i]);
    }
    return .{ .input = input, .target = val };
}

test "init" {
    const expect = std.testing.expect;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) expect(false) catch @panic("TEST FAIL");
    }

    var prng: std.Random.DefaultPrng = .init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();
    var scheduler = try Scheduler.init(allocator, rand);
    defer scheduler.deinit();
    try scheduler.spawnOrganism(1, 10, 1000);
    _ = try Scheduler.execute(
        scheduler.cpus.items,
        &scheduler.cpus.items[0],
        &scheduler.soup,
        scheduler.allocator,
        rand,
        scheduler.challengeTarget,
        &scheduler.stats,
    );
}
