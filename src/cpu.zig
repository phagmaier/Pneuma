const std = @import("std");
const Op = @import("op.zig").Op;
const REGSIZE: u8 = 4;
const STACKSIZE: u8 = 8;
const ENERGY: u32 = 1000;
pub const MAXENERGY: u32 = 10_000;
const MAXPULL: u32 = 64;
const MAXINJECT: u32 = 32;
const INJECTCOST: u32 = 3;
const MERGECOST: u32 = 2;
const EXTENDCOST: u32 = 50;
const GROWSTACK: u32 = 8;

pub const MutResult = struct {
    value: u32,
    insert_before: ?u32, // if set, write this random opcode before the value
    skip: bool, // deletion — don't write the value at all
};

pub fn mutate(value: u32, rand: std.Random) MutResult {
    // Deletion: 1/5000 — skip this instruction entirely
    if (rand.intRangeLessThan(u32, 0, 5000) == 0) {
        return .{ .value = value, .insert_before = null, .skip = true };
    }

    // Insertion: 1/5000 — insert a random opcode before this one
    const insert: ?u32 = if (rand.intRangeLessThan(u32, 0, 5000) == 0)
        Op.randOp(rand)
    else
        null;

    // Point mutation: 1/2000 — replace with random opcode
    const mutated = if (rand.intRangeLessThan(u32, 0, 2000) == 0)
        Op.randOp(rand)
    else
        value;

    return .{ .value = mutated, .insert_before = insert, .skip = false };
}

pub const Cpu = struct {
    id: u32,
    start: u32,
    size: u32,
    registers: []u32,
    stack: []u32,
    stackptr: u32,
    ip: u32,
    energy: u32,
    age: u32,
    cost: u32,
    childStart: u32,
    childSize: u32,
    harvested: bool,

    pub fn init(allocator: std.mem.Allocator, id: u32, start: u32, size: u32) !Cpu {
        const registers = try allocator.alloc(u32, REGSIZE);
        @memset(registers, 0);
        const stack = try allocator.alloc(u32, STACKSIZE);
        @memset(stack, 0);
        return .{
            .id = id,
            .start = start,
            .size = size,
            .registers = registers,
            .stack = stack,
            .stackptr = 0,
            .ip = start,
            .energy = ENERGY,
            .age = 0,
            .cost = 0,
            .childStart = 0,
            .childSize = 0,
            .harvested = false,
        };
    }

    pub fn initChild(allocator: std.mem.Allocator, id: u32, start: u32, size: u32, numRegs: usize, stackDepth: usize, energy: u32) !Cpu {
        const registers = try allocator.alloc(u32, numRegs);
        @memset(registers, 0);
        const stack = try allocator.alloc(u32, stackDepth);
        @memset(stack, 0);
        return .{
            .id = id,
            .start = start,
            .size = size,
            .registers = registers,
            .stack = stack,
            .stackptr = 0,
            .ip = start,
            .energy = energy,
            .age = 0,
            .cost = 0,
            .childStart = 0,
            .childSize = 0,
            .harvested = false,
        };
    }

    pub fn growStack(self: *Cpu, allocator: std.mem.Allocator) !void {
        const oldSize = self.stack.len;
        self.stack = try allocator.realloc(self.stack, GROWSTACK + oldSize);
        @memset(self.stack[oldSize..], 0);
    }
    pub fn growRegisters(self: *Cpu, allocator: std.mem.Allocator) !void {
        const oldSize = self.registers.len;
        self.registers = try allocator.realloc(self.registers, oldSize + 1);
        @memset(self.registers[oldSize..], 0);
    }

    pub fn shrinkStack(self: *Cpu, allocator: std.mem.Allocator) !void {
        const size = self.stack.len;
        if (size == 0) return;
        self.stack = try allocator.realloc(self.stack, size - 1);
        self.stackptr = @min(self.stackptr, @as(u32, @intCast(self.stack.len)));
    }

    pub fn shrinkRegisters(self: *Cpu, allocator: std.mem.Allocator) !void {
        const size = self.registers.len;
        if (size == 0) return;
        self.registers = try allocator.realloc(self.registers, size - 1);
    }

    pub fn push(self: *Cpu, val: u32) bool {
        if (self.stackptr == self.stack.len) return false;
        self.stack[self.stackptr] = val;
        self.stackptr += 1;
        return true;
    }

    pub fn pop(self: *Cpu) ?u32 {
        if (self.stackptr == 0) return null;
        self.stackptr -= 1;
        return self.stack[self.stackptr];
    }

    pub fn inc(self: *Cpu, soupSize: u32) void {
        self.ip = @mod(self.ip +% 1, soupSize);
    }
    pub fn boundWrap(idx: u32, soupSize: u32, start: u32, size: u32) u32 {
        return @mod(start + @mod(idx -% start, size), soupSize);
    }

    fn decCpus(id: u32, cpus: []Cpu) void {
        for (cpus) |*cpu| {
            if (cpu.id == id) {
                cpu.energy -|= 1;
                break;
            }
        }
    }

    fn getReg(self: *const Cpu, idx: u8) u32 {
        return if (idx < self.registers.len) self.registers[idx] else 0;
    }

    pub fn pull(self: *Cpu, mem: []u32, occ: []?u32, cpus: []Cpu, rand: std.Random) void {
        const size = @min(MAXPULL, self.getReg(2), self.energy);
        const soupSize = @as(u32, @intCast(mem.len));
        const source = @mod(self.getReg(0), soupSize);
        const start = self.start;
        const destBase = boundWrap(self.getReg(1), soupSize, start, self.size);
        var dstOff: u32 = 0;
        for (0..size) |i| {
            const srcOff: u32 = @intCast(i);
            const s = @mod(source + srcOff, soupSize);

            // Source organism loses energy regardless of mutation outcome
            if (occ[s]) |id| {
                decCpus(id, cpus);
            }

            const mr = mutate(mem[s], rand);

            // Deletion — skip writing this instruction
            if (mr.skip) continue;

            // Insertion — write a random opcode before the actual value
            if (mr.insert_before) |ins| {
                const d = boundWrap(destBase + dstOff, soupSize, start, self.size);
                mem[d] = ins;
                dstOff += 1;
            }

            // Write the (possibly point-mutated) value
            const d = boundWrap(destBase + dstOff, soupSize, start, self.size);
            mem[d] = mr.value;
            dstOff += 1;
        }
        if (size > 0) self.cost = size;
    }

    pub fn inject(self: *Cpu, mem: []u32) void {
        const size = @min(MAXINJECT, self.getReg(2), self.energy / INJECTCOST);
        const soupSize = @as(u32, @intCast(mem.len));
        const start = self.start;
        const source = boundWrap(self.getReg(0), soupSize, start, self.size);
        const dest = @mod(self.getReg(1), soupSize);
        for (0..size) |i| {
            const offset: u32 = @intCast(i);
            const s = boundWrap(source + offset, soupSize, start, self.size);
            const d = @mod(dest + offset, soupSize);
            if (d != 0) {
                mem[d] = mem[s];
            }
        }
        if (size > 0) self.cost = size * INJECTCOST;
    }

    pub fn merge(self: *Cpu, occ: []?u32, scavenge: []u32) void {
        const maxSize = @min(self.getReg(2), self.energy / MERGECOST);
        const soupSize = @as(u32, @intCast(occ.len));
        const expectedStart = @mod(self.start + self.size, soupSize);
        const start = @mod(self.getReg(0), soupSize);
        if (start != expectedStart or start == 0) return;
        var count: u32 = 0;
        for (0..maxSize) |i| {
            const idx = @mod(start + @as(u32, @intCast(i)), soupSize);
            if (idx == 0) {
                break;
            } else if (occ[idx]) |_| {
                break;
            } else {
                self.size += 1;
                occ[idx] = self.id;
                self.energy = @min(self.energy + scavenge[idx], MAXENERGY);
                scavenge[idx] = 0;
                count += 1;
            }
        }
        if (count > 0) self.cost = count * MERGECOST;
    }

    pub fn maintenanceCost(self: *const Cpu) u32 {
        var maint: u32 = 0;
        if (self.registers.len > REGSIZE) {
            maint += @as(u32, @intCast(self.registers.len - REGSIZE));
        }
        if (self.stack.len > STACKSIZE) {
            maint += @as(u32, @intCast((self.stack.len - STACKSIZE) / GROWSTACK));
        }
        // Max age: organism dies after 10000 ticks without replicating
        // Replication resets age to 0, so active replicators are not affected
        if (self.age > 8000) {
            maint += (self.age - 8000) / 500;
        }
        return maint;
    }

    pub fn deinit(self: *Cpu, allocator: std.mem.Allocator) void {
        allocator.free(self.registers);
        allocator.free(self.stack);
    }
};
