const std = @import("std");

const NaNBox = @import("NaNBox.zig").NaNBox;

pub const InstType = enum {
    push,
    swap,
    fadd,
    fdiv,
    fsub,
    dup,
    dec,
    cmp,
    jne,
    dmp,
    pop,
    add,
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
            []const u8 => if (v.len > 128) {
                unreachable;
            } else return .{ .Str = v },
            else       => @compileError("Unsupported type: " ++ @typeName(T) ++ "\n")
        };
    }
};

pub const Inst = struct {
    ty: InstType,
    v: InstValue,

    const Self = @This();

    pub inline fn new(ty: InstType, v: InstValue) Self {
        comptime return .{ .ty = ty, .v = v };
    }
};
