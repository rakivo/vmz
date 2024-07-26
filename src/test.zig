const std = @import("std");

pub const InstType = enum {
    push, pop,

    fadd, fdiv, fsub, fmul,

    iadd, idiv, isub, imul,

    inc, dec,

    jmp, je, jne, jg, jl, jle, jge,

    swap, dup,

    cmp, dmp, nop, label, native, alloc, halt,
};

const NaNBox = struct {
    v: f64
};

pub const InstValue = union(enum) {
    U8: u8,
    I64: i64,
    U64: u64,
    F64: f64,
    None: void,
    NaN: NaNBox,
    Str: []const u8,
};

pub const Inst = struct {
    type: InstType,
    value: InstValue,
};

pub const Parsed = struct {
    ip: u64,
    im: std.AutoHashMap(u64, Inst),
    lm: std.StringHashMap(u64),
    program: std.ArrayList(Inst),
};

pub fn main() !void {
    const parsed = Parsed {
        .im = std.AutoHashMap(u64, Inst).init(std.heap.page_allocator),
        .lm = std.StringHashMap(u64).init(std.heap.page_allocator),
        .program = std.ArrayList(Inst).init(std.heap.page_allocator)
    };

    var it = parsed.lm.keyIterator();
    while (it.next()) |key|
        std.debug.print("{}\n", .{key});
}
