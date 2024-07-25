const std     = @import("std");
const builtin = @import("builtin");
const vm      = @import("vm.zig").Vm;
const nan_mod = @import("NaNBox.zig");
const Token   = @import("lexer.zig").Token;

const NaNBox = nan_mod.NaNBox;
const Type   = nan_mod.Type;

const print = std.debug.print;
const exit  = std.process.exit;

// Note for developers: update `arg_required` and `expected_types` functions if you add a new instruction here.
pub const InstType = enum {
    push, pop,

    fadd, fdiv, fsub, fmul,

    iadd, idiv, isub, imul,

    inc, dec,

    jmp, je, jne, jg, jl, jle, jge,

    swap, dup,

    cmp, dmp, nop, label, native, alloc, halt,

    const Self = @This();

    pub inline fn to_bytes(self: *const Self) u8 {
        const int: u8 = @intFromEnum(self.*);
        return int;
    }

    pub fn try_from_str(str: []const u8) ?Self {
        return inline for (std.meta.fields(Self)) |f| {
            if (std.mem.eql(u8, f.name, str))
                return @enumFromInt(f.value);
        } else null;
    }

    pub fn arg_required(self: Self) bool {
        return switch (self) {
            .alloc, .native, .push, .jmp, .je, .jne, .jg, .jl, .jle, .jge, .swap, .dup => true,
            else => false,
        };
    }

    pub fn expected_types(self: Self) []const Token.Type {
        return switch (self) {
            .jmp, .je, .jne, .jg, .jl, .jle, .jge => &[_]Token.Type{.str, .int, .literal},
            .native => &[_]Token.Type{.str, .literal},
            .push => &[_]Token.Type{.int, .str, .char, .float},
            .alloc, .swap, .dup => &[_]Token.Type{.int},
            else  => &[_]Token.Type{},
        };
    }
};

pub const INST_CAP = 14 + 1 + 1;
pub const None = InstValue.new(void, {});

const InstValueType = enum {
    NaN, None, I64, U64, F64, Str,
};

pub const InstValue = union(enum) {
    U8: u8,
    I64: i64,
    U64: u64,
    F64: f64,
    None: void,
    NaN: NaNBox,
    Str: []const u8,

    const Self = @This();

    const STR_CAP = 14;

    pub inline fn to_bytes(self: *const Self) ![INST_CAP]u8 {
        var ret: [INST_CAP]u8 = undefined;
        var size: usize = 0;
        size += 1;
        ret[size] = @intFromEnum(self.*);
        size += 1;
        switch (self.*) {
            .NaN => |nan| {
                std.mem.copyForwards(u8, ret[size..size + 8], &std.mem.toBytes(nan.v));
                size += 8;
            },
            .I64 => |int| {
                std.mem.copyForwards(u8, ret[size..size + 8], &std.mem.toBytes(int));
                size += 8;
            },
            .U64 => |int| {
                std.mem.copyForwards(u8, ret[size..size + 8], &std.mem.toBytes(int));
                size += 8;
            },
            .F64 => |f| {
                std.mem.copyForwards(u8, ret[size..size + 8], &std.mem.toBytes(f));
                size += 8;
            },
            .Str => |str| {
                if (str.len > STR_CAP - size)
                    return error.STR_IS_TOO_LONG;

                ret[size] = @intCast(str.len);
                size += 1;
                std.mem.copyForwards(u8, ret[size..size + str.len], str);
                size += str.len;
            },
            else => {},
        }
        return ret;
    }

    pub inline fn g8b(bytes: []const u8) [8]u8 {
        return [8]u8 {
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
        };
    }

    pub fn from_bytes(bytes: []const u8) !Inst {
        var idx: usize = 0;
        const ty: InstType = @enumFromInt(bytes[idx]);
        idx += 1;
        const vty: InstValueType = @enumFromInt(bytes[idx]);
        idx += 1;

        return switch (vty) {
            .NaN => {
                const f: f64 = @bitCast(g8b(bytes[idx..idx + 8]));
                return Inst.new(ty, InstValue.new(NaNBox, NaNBox { .v = f }));
            },
            .I64 => {
                const int: i64 = @bitCast(g8b(bytes[idx..idx + 8]));
                return Inst.new(ty, InstValue.new(i64, int));
            },
            .U64 => {
                const int: u64 = @bitCast(g8b(bytes[idx..idx + 8]));
                return Inst.new(ty, InstValue.new(u64, int));
            },
            .F64 => {
                const f: f64 = @bitCast(g8b(bytes[idx..idx + 8]));
                return Inst.new(ty, InstValue.new(f64, f));
            },
            .Str => {
                const len = bytes[idx];
                idx += 1;
                const str = bytes[idx..idx + len];
                return Inst.new(ty, InstValue.new([]const u8, str));
            },
            else => {
                return Inst.new(ty, None);
            }
        };
    }

    pub inline fn new(comptime T: type, v: T) Self {
        return switch (T) {
            u8         => .{ .U8 = v },
            i64        => .{ .I64 = v },
            f64        => .{ .F64 = v },
            u64        => .{ .U64 = v },
            void       => .{ .None = {} },
            NaNBox     => .{ .NaN = v },
            []const u8 => if (v.len > 1) {
                if (v.len - 1 >= vm.STR_CAP) {
                    const cap: usize = if (v.len - 1 >= vm.STACK_CAP) vm.STACK_CAP else vm.STR_CAP;
                    print("String length: {} is greater than the maximum capacity {}\n", .{v.len, cap});
                    exit(1);
                } else return .{ .Str = v };
            } else return .{ .Str = &[_]u8{} },
            else       => @compileError("Unsupported type: " ++ @typeName(T) ++ "\n")
        };
    }
};

pub const Inst = struct {
    type: InstType,
    value: InstValue,

    const Self = @This();

    pub inline fn from_bytes(bytes: []const u8) !Inst {
        std.debug.assert(bytes.len == INST_CAP);
        return InstValue.from_bytes(bytes);
    }

    pub inline fn to_bytes(self: *const Self) ![INST_CAP]u8 {
        var bytes = try self.value.to_bytes();
        bytes[0] = self.type.to_bytes();
        return bytes;
    }

    pub inline fn new(typ: InstType, value: InstValue) Self {
        return .{ .type = typ, .value = value };
    }
};
