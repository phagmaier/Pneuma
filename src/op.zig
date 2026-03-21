const std = @import("std");
pub const Op = enum(u32) {
    nop0,
    nop1,
    or1,
    shl,
    zero,
    ifCZ,
    subAB,
    subAC,
    incA,
    incB,
    decC,
    pushA,
    popA,
    popB,
    popC,
    adrf,
    adrb,
    call,
    ret,
    movAB,
    movCD,
    mal,
    div,
    scan,
    pull,
    inject,
    merge,
    harvest,
    extend,
    shrink,
    movRA,
    movAR,
    copy,
    load,

    pub fn toNum(op: Op) u32 {
        return @as(u32, @intFromEnum(op));
    }
    pub fn toOp(num: u32) Op {
        return @as(Op, @enumFromInt(num));
    }
    pub fn randOp(rand: std.Random) u32 {
        const size = @as(u32, @typeInfo(Op).@"enum".fields.len - 1);
        return rand.intRangeAtMost(u32, 0, size);
    }
};
