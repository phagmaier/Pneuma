const std = @import("std");
const Op = @import("op.zig").Op;
const Soup = @import("soup.zig").Soup;
const cpu_mod = @import("cpu.zig");
const Cpu = cpu_mod.Cpu;
const SIZE = Soup.SIZE;
const MAXENERGY = cpu_mod.MAXENERGY;
const T_CHALLENGE: u32 = 1500;
const E_HARVEST: u32 = 600;

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

pub const Scheduler = struct {
    tick: u32,
    nextId: u32,
    challengeTarget: u32,
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
            .challengeTarget = 0,
            .challengeTimer = 0,
            .allocator = allocator,
            .rand = rand,
            .cpus = std.ArrayList(Cpu).empty,
            .soup = try Soup.init(allocator),
            .stats = .{},
        };
        sched.challengeTarget = generateTarget(sched.tick, rand);
        sched.soup.mem[0] = sched.challengeTarget;
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
        const id = self.nextId;
        self.nextId += 1;
        var cpu = try Cpu.init(self.allocator, id, start, size);
        cpu.energy = energy;
        self.soup._claim(id, start, size);
        try self.cpus.append(self.allocator, cpu);
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

    pub fn execute(cpus: []Cpu, cpu: *Cpu, soup: *Soup, allocator: std.mem.Allocator, rand: std.Random, challengeTarget: u32) !bool {
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
                if (cpySize > 0 and cpySize <= cpu.size) {
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
                        soup.mem[dst] = ins;
                        dst = Soup.incWrap(dst);
                    }
                    soup.mem[dst] = mr.value;
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

    pub fn doTick(self: *Scheduler) !void {
        // 1. Shuffle execution order
        self.shuffle();

        // 2-6. Execute each organism, handle energy + death
        var newborns = std.ArrayList(Cpu).empty;
        defer newborns.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.cpus.items.len) {
            var cpu = &self.cpus.items[i];

            // 2. Execute 1 instruction (sets cpu.cost)
            const divHappened = try execute(self.cpus.items, cpu, &self.soup, self.allocator, self.rand, self.challengeTarget);

            // Handle DIVIDE — spawn child before energy deduction
            if (divHappened) {
                try self.spawnChild(cpu, &newborns);
            }

            // 3. Deduct per-instruction energy cost
            if (cpu.energy <= cpu.cost) {
                self.kill(i);
                continue;
            }
            cpu.energy -= cpu.cost;

            // 5. Deduct baseline (2) + hardware maintenance costs
            const maint = cpu.maintenanceCost();
            if (cpu.energy <= maint) {
                self.kill(i);
                continue;
            }
            cpu.energy -= maint;

            cpu.age += 1;
            i += 1;
        }

        // Add newborn children (they execute next tick)
        for (newborns.items) |child| {
            try self.cpus.append(self.allocator, child);
        }

        // 7. Deposit passive energy at 10000 random addresses
        for (0..10000) |_| {
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
            const cosmicAddr = self.rand.intRangeLessThan(u32, 0, SIZE);
            self.soup.mem[cosmicAddr] = Op.randOp(self.rand);
        }

        // 9. Challenge timer
        self.challengeTimer += 1;
        if (self.challengeTimer >= T_CHALLENGE) {
            self.challengeTimer = 0;
            self.challengeTarget = generateTarget(self.tick, self.rand);
            self.soup.mem[0] = self.challengeTarget;
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
        // 41-instruction self-replicating ancestor with harvest
        const program = [_]u32{
            // Start marker: nop1 nop1 nop0 nop0  (pos 0-3)
            n(.nop1),  n(.nop1),  n(.nop0),  n(.nop0),
            // Harvest: AX=0 → load mem[0] (challenge target) → harvest  (pos 4-6)
            n(.zero),
            n(.load),
            n(.harvest),
            // ADRB to find start marker  (pos 7)
            n(.adrb),
            // Template: 1 1 0 0 (backward search matches start marker 1 1 0 0)  (pos 8-11)
            n(.nop1),  n(.nop1),  n(.nop0),  n(.nop0),
            // Save start in stack, find end  (pos 12-13)
            n(.pushA),
            n(.adrf),
            // Template: 1 1 0 0 (forward complement search matches end marker 0 0 1 1)  (pos 14-17)
            n(.nop1),  n(.nop1),  n(.nop0),  n(.nop0),
            // BX=start, CX=length, allocate child  (pos 18-20)
            n(.popB),
            n(.subAB),
            n(.mal),
            // Save child_start  (pos 21)
            n(.pushA),
            // Copy loop marker: nop0 nop1  (pos 22-23)
            n(.nop0),  n(.nop1),
            // Copy loop body: restore AX, discard CALL return addr  (pos 24-25)
            n(.popA),
            n(.popA),
            // Copy one instruction with mutation  (pos 26)
            n(.copy),
            // Advance pointers  (pos 27-29)
            n(.incA),
            n(.incB),
            n(.decC),
            // If CX!=0 skip DIVIDE  (pos 30)
            n(.ifCZ),
            // CX==0: spawn child  (pos 31)
            n(.div),
            // Save AX, find copy loop, jump back  (pos 32-36)
            n(.pushA),
            n(.adrb),
            // Template: 0 1 (backward search matches copy loop marker 0 1)  (pos 34-35)
            n(.nop0),  n(.nop1),
            // CALL jumps to copy loop  (pos 36)
            n(.call),
            // End marker: nop0 nop0 nop1 nop1  (pos 37-40)
            n(.nop0),  n(.nop0),  n(.nop1),  n(.nop1),
        };

        const size: u32 = program.len;
        // Write program into soup memory
        for (program, 0..) |inst, i| {
            const idx = Soup.wrap(addr + @as(u32, @intCast(i)));
            self.soup.mem[idx] = inst;
        }
        // Spawn organism at this address
        try self.spawnOrganism(addr, size, energy);
    }
};

fn applyRandomOp(val: u32, rand: std.Random) u32 {
    return switch (rand.intRangeAtMost(u32, 0, 3)) {
        0 => val +| 1,
        1 => val -| 1,
        2 => std.math.shl(u32, val, 1),
        3 => val | 1,
        else => val,
    };
}

fn generateTarget(tick: u32, rand: std.Random) u32 {
    if (tick < 50_000) {
        // Epoch 1: constant 0–31 (ancestor uses LOAD to read target from mem[0])
        return rand.intRangeAtMost(u32, 0, 31);
    } else if (tick < 200_000) {
        // Epoch 2: 2 operations on a small constant
        var val = rand.intRangeAtMost(u32, 0, 15);
        val = applyRandomOp(val, rand);
        val = applyRandomOp(val, rand);
        return val;
    } else {
        // Epoch 3: 3–5 operations on a small constant
        var val = rand.intRangeAtMost(u32, 0, 7);
        const numOps = rand.intRangeAtMost(u32, 3, 5);
        var j: u32 = 0;
        while (j < numOps) : (j += 1) {
            val = applyRandomOp(val, rand);
        }
        return val;
    }
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
    var cpu = try Cpu.init(allocator, 0, 0, 10);
    try scheduler.cpus.append(scheduler.allocator, cpu);
    _ = try Scheduler.execute(scheduler.cpus.items, &cpu, &scheduler.soup, scheduler.allocator, rand, scheduler.challengeTarget);
}
