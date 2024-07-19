const std    = @import("std");
const NaNBox = @import("NaNBox.zig").NaNBox;
const vm     = @import("vm.zig").Vm;

const print = std.debug.print;

pub const InstType = enum {
    push, pop,

    fadd, fdiv, fsub, fmul,

    iadd, idiv, isub, imul,

    inc, dec,

    je, jne, jg, jl, jle, jge,

    swap, dup,

    cmp, dmp,

    nop,
};

pub const None = InstValue.new(void, {});

pub const InstValue = union(enum) {
    Nan: NaNBox,
    None: void,
    I64: i64,
    U64: u64,
    F64: f64,
    Str: []const u8,

    const Self = @This();

    pub inline fn new(comptime T: type, v: T) Self {
        return comptime switch (T) {
            i64        => .{ .I64 = v },
            f64        => .{ .F64 = v },
            u64        => .{ .U64 = v },
            void       => .{ .None = {} },
            NaNBox     => .{ .Nan = v },
            []const u8 => if (v.len - 1 >= vm.STR_CAP) {
                const cap = if (v.len - 1 >= vm.STACK_CAP) vm.STACK_CAP else vm.STR_CAP;
                @compileError("String length: " ++ v.len ++  " is greater than the maximum capacity: " ++ cap ++ "\n");
            } else return .{ .Str = v },
            else       => @compileError("Unsupported type: " ++ @typeName(T) ++ "\n")
        };
    }
};

pub const Inst = struct {
    type: InstType,
    value: InstValue,

    const Self = @This();

    pub inline fn new(typ: InstType, value: InstValue) Self {
        comptime return .{ .type = typ, .value = value };
    }
};
