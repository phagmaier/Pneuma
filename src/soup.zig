const std = @import("std");
const print = std.debug.print;
//pub const SIZE: u32 = 131_072;
//Circular buffer of instruction slots. Start with 131,072 slots (2^17). This is tunable but needs to be large enough that geographic isolation can occur and small enough that organisms encounter each other regularly.
//Each slot holds one instruction (represented as an integer opcode) or is empty (NOP/dead).
//Memory wraps around — address 131071 + 1 = address 0.
//All addresses are globally readable. Writing to addresses you don't own requires the INJECT instruction.

pub const Soup = struct {
    pub const SIZE: u32 = 131_072;
    pub const RESERVED_PREFIX_LEN: u32 = 4;
    mem: []u32,
    occupied: []?u32,
    scavenge: []u32,

    pub fn init(allocator: std.mem.Allocator) !Soup {
        const mem = try allocator.alloc(u32, SIZE);
        const occupied = try allocator.alloc(?u32, SIZE);
        const scavenge = try allocator.alloc(u32, SIZE);
        @memset(mem, 0);
        @memset(occupied, null);
        @memset(scavenge, 0);
        return .{ .mem = mem, .occupied = occupied, .scavenge = scavenge };
    }
    pub fn wrap(idx: u32) u32 {
        return idx % SIZE;
    }
    pub fn isReserved(idx: u32) bool {
        return wrap(idx) < RESERVED_PREFIX_LEN;
    }
    pub fn incWrap(idx: u32) u32 {
        return @mod(idx +% 1, SIZE);
    }
    pub fn subWrap(idx: u32) u32 {
        return @mod(idx -% 1, SIZE);
    }
    pub fn getOccupant(self: *Soup, _idx: u32) ?u32 {
        const idx = wrap(_idx);
        return self.occupied[idx];
    }
    pub fn isOccupied(self: *Soup, idx: u32) bool {
        if (isReserved(idx)) return true;
        const occupant = self.getOccupant(idx);
        if (occupant) |_| {
            return true;
        }
        return false;
    }
    pub fn push(self: *Soup, _idx: u32, inst: u32) void {
        const idx = wrap(_idx);
        self.mem[idx] = inst;
    }

    pub fn setChild(self: *Soup, childStart: u32, childSize: u32, cpuStart: u32, childId: u32) void {
        for (0..childSize) |i| {
            const pIdx = wrap(@as(u32, @intCast(cpuStart + i)));
            const cIdx = wrap(@as(u32, @intCast(childStart + i)));
            self.mem[cIdx] = self.mem[pIdx];
            self.occupied[cIdx] = childId;
        }
    }

    pub fn _claim(self: *Soup, id: u32, start: u32, size: u32) void {
        for (0..size) |i| {
            const idx = wrap(@as(u32, @intCast(start + i)));
            self.occupied[idx] = id;
        }
    }

    pub fn claim(self: *Soup, start: u32, size: u32, id: u32, searchSize: u32) ?u32 {
        const newStart = self.findFree(start, size, searchSize) orelse return null;
        self._claim(id, newStart, size);
        return newStart;
    }

    pub fn findFree(self: *Soup, start: u32, size: u32, searchSize: u32) ?u32 {
        var count: u32 = 0;
        var newStart: u32 = start;
        for (0..searchSize) |i| {
            const offset: u32 = @intCast(i);
            const idx = wrap(start + offset);
            if (self.isOccupied(idx)) {
                count = 0;
            } else {
                count += 1;
                if (count == 1) newStart = start + offset;
                if (count == size) {
                    return wrap(newStart);
                }
            }
        }
        return null;
    }

    pub fn getOp(self: *const Soup, idx: u32) u32 {
        return self.mem[wrap(idx)];
    }

    pub fn free(self: *Soup, start: u32, size: u32) void {
        for (0..size) |i| {
            const idx = wrap(@as(u32, @intCast(start + i)));
            self.occupied[idx] = null;
        }
    }

    pub fn deinit(self: *Soup, allocator: std.mem.Allocator) void {
        allocator.free(self.scavenge);
        allocator.free(self.occupied);
        allocator.free(self.mem);
    }

    fn matchesAt(mem: []const u32, start: u32, pattern: []const bool) bool {
        var idx = start;
        for (pattern) |item| {
            const val: bool = switch (mem[idx]) {
                0 => true,
                1 => false,
                else => return false,
            };
            if (val != item) return false;
            idx = incWrap(idx);
        }
        return true;
    }

    pub fn scanSearch(self: *Soup, ip: u32, allocator: std.mem.Allocator) !?u32 {
        const mem = self.mem;
        var pattern = std.ArrayList(bool).empty;
        defer pattern.deinit(allocator);

        const templateStart = incWrap(ip);
        if (mem[templateStart] != 0 and mem[templateStart] != 1) return null;
        _ = try fillPattern(mem, &pattern, allocator, templateStart);
        if (pattern.items.len == 0) return null;

        // Alternate forward/backward from IP, up to half the soup
        const maxDist: u32 = SIZE / 2;
        var dist: u32 = 1;
        while (dist <= maxDist) : (dist += 1) {
            const fwd = wrap(ip +% dist);
            if (matchesAt(mem, fwd, pattern.items)) return fwd;

            const bwd = wrap(ip -% dist);
            if (matchesAt(mem, bwd, pattern.items)) return bwd;
        }

        return null;
    }

    fn fillPattern(mem: []const u32, pattern: *std.ArrayList(bool), allocator: std.mem.Allocator, start: u32) !u32 {
        var idx = start;
        while (mem[idx] == 0 or mem[idx] == 1) {
            // Store the COMPLEMENT: NOP_0 (0) -> false, NOP_1 (1) -> true
            const item = if (mem[idx] == 0) false else true;
            try pattern.append(allocator, item);
            idx = incWrap(idx);
        }
        return idx; // return position after the template
    }

    pub fn search(self: *Soup, templateStart: u32, searchStart: u32, allocator: std.mem.Allocator, reverse: bool) !?u32 {
        const mem = self.mem;
        var pattern = std.ArrayList(bool).empty;
        defer pattern.deinit(allocator);
        if (mem[templateStart] != 0 and mem[templateStart] != 1) return null;
        const afterTemplate = try fillPattern(mem, &pattern, allocator, templateStart);
        if (pattern.items.len == 0) return null;
        // Start searching from searchStart (forward: after template, backward: before IP)
        var idx = if (reverse) searchStart else afterTemplate;
        var count: u32 = 0;
        for (0..SIZE) |_| {
            const cpy = idx;
            count = 0;
            for (pattern.items) |item| {
                const val: bool = switch (mem[idx]) {
                    0 => true,
                    1 => false,
                    else => break,
                };
                if (val == item) count += 1 else break;
                idx = if (reverse) subWrap(idx) else incWrap(idx);
            }
            if (count == pattern.items.len) {
                // For backward search, idx is one before the match start (in forward order)
                // Return the first address of the matched pattern
                return if (reverse) incWrap(idx) else idx;
            }
            idx = if (reverse) subWrap(cpy) else incWrap(cpy);
        }
        return null;
    }
};

test "init" {
    const expect = std.testing.expect;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) expect(false) catch @panic("TEST FAIL");
    }
    var soup = try Soup.init(allocator);
    defer soup.deinit(allocator);
}
