const std    = @import("std");
const vm     = @import("vm.zig").Vm;
const Token  = @import("lexer.zig").Token;
const NaNBox = @import("NaNBox.zig").NaNBox;

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

    cmp, dmp, nop, label, halt,

    const Self = @This();

    pub fn try_from_str(str: []const u8) ?Self {
        return inline for (std.meta.fields(Self)) |f| {
            if (std.mem.eql(u8, f.name, str))
                return @enumFromInt(f.value);
        } else null;
    }

    pub fn arg_required(self: Self) bool {
        return switch (self) {
            .push, .jmp, .je, .jne, .jg, .jl, .jle, .jge, .swap, .dup => true,
            else => false,
        };
    }

    pub fn expected_types(self: Self) []const Token.Type {
        return switch (self) {
            .jmp, .je, .jne, .jg, .jl, .jle, .jge => &[_]Token.Type{.str, .int, .literal},
            .push => &[_]Token.Type{.int, .str, .float},
            .swap => &[_]Token.Type{.int},
            .dup  => &[_]Token.Type{.int},
            else  => &[_]Token.Type{},
        };
    }
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
        return switch (T) {
            i64        => .{ .I64 = v },
            f64        => .{ .F64 = v },
            u64        => .{ .U64 = v },
            void       => .{ .None = {} },
            NaNBox     => .{ .Nan = v },
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

    pub inline fn new(typ: InstType, value: InstValue) Self {
        return .{ .type = typ, .value = value };
    }
};
