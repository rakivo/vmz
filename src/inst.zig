const std       = @import("std");
const builtin   = @import("builtin");
const vm_mod    = @import("vm.zig");
const nan_mod   = @import("NaNBox.zig");
const lexer_mod = @import("lexer.zig");

const Token       = lexer_mod.Token;
const ComptimeBuf = lexer_mod.ComptimeBuf;

const Vm          = vm_mod.Vm;
const STR_CAP     = Vm.STR_CAP;
const STACK_CAP   = Vm.STACK_CAP;
const panic       = vm_mod.panic;

const NaNBox      = nan_mod.NaNBox;
const Type        = nan_mod.Type;

pub const CHUNK_SIZE = 10;
pub const STRING_PLACEHOLDER: *const [8:0]u8 = "$STRING$";

// Note for developers: update `arg_required` and `expected_types` functions if you add a new instruction here.
pub const InstType = enum {
    // push/pop to stack
    push,
    pop,

    // push/pop to strings
    spush,
    spop,

    // float math
    fadd, fdiv, fsub, fmul,

    // int math
    iadd, idiv, isub, imul,

    inc, dec,

    // jump if top of the stack is true, that is how we get the boolean from the value:
    // ```
    // const boolean = switch (b.getType()) {
    //     .Bool => b.as(bool),
    //     .F64 => b.as(f64) > 0.0,
    //     .U8, .I64, .U64, .Str => b.as(u64) > 0,
    // };
    // ```
    jmp_if,

    jmp, je, jz, jnz, jne, jg, jl, jle, jge,

    swap, dup,

    // read content from file descriptor (stdin/stdout/stderr, from file)
    fread,

    // exact read (read exact index from memory)
    eread,

    // read a region of memory and push in onto the stack
    read,

    // write a region of memory to file descriptor (stdin/stdout/stderr, to file)
    fwrite,

    // exact write (write exact index of memory)
    write,

    // push memory pointer onto the stack (basically just amount of used memory)
    pushmp,

    // push stack length onto the stack
    pushsp,

    call,
    ret,

    cmp,

    // print last element on the stack to the stdout
    dmp,

    // pushes onto the stack size of the last element, calculated this way:
    // if the element is string, it pushes its length,
    // if it's buffer pointer, it pushes the length of the slice on which pointer points.
    // otherwise, it pushes its size in bytes.
    sizeof,

    // print last element + newline on the stack to the stdout
    dmpln,

    // added just for consistency, use `<your_label>:` syntax
    label,

    // allocate memory on the heap.
    alloc,

    // call a native function from provided native functions map
    native,

    // no operation
    nop,

    // logical not
    not,

    // halt the vm
    halt,

    const Self = @This();

    pub fn try_from_str(str: []const u8) ?Self {
        return inline for (std.meta.fields(Self)) |f| {
            if (std.mem.eql(u8, f.name, str))
                return @enumFromInt(f.value);
        } else null;
    }

    pub fn to_str(self: Self) []const u8 {
        return @tagName(self);
    }

    pub fn arg_required(self: Self) bool {
        return switch (self) {
            .cmp, .jmp_if, .swap, .spush, .call, .alloc, .native, .push, .jmp, .jz, .jnz, .je, .jne, .jg, .jl, .jle, .jge, .dup => true,
            else => false,
        };
    }

    pub fn expected_types(self: Self) []const Token.Type {
        return switch (self) {
            .jmp_if, .jmp, .jz, .jnz, .je, .jne, .jg, .jl, .jle, .jge => &[_]Token.Type{.str, .int, .literal},
            .call, .native => &[_]Token.Type{.str, .literal},
            .fread => &[_]Token.Type{.int, .str},
            .spush => &[_]Token.Type{.int, .str, .char},
            .push => &[_]Token.Type{.int, .str, .char, .float, .buf_expr},
            .alloc, .swap, .dup => &[_]Token.Type{.int},
            .cmp, .dmp, .dmpln => &[_]Token.Type{.literal},
            else  => &[_]Token.Type{},
        };
    }
};

pub const None = InstValue.new(void, {});

pub const InstValueType = enum {
    U8, I64, U64, F64, None, NaN, Str, Type,

    const Self = @This();

    pub fn try_from_str(str: []const u8) ?Self {
        return inline for (std.meta.fields(Self)) |f| {
            if (std.mem.eql(u8, f.name, str))
                return @enumFromInt(f.value);
        } else null;
    }
};

pub const InstValue = union(enum) {
    U8: u8,
    I64: i64,
    U64: u64,
    F64: f64,
    None: void,
    NaN: NaNBox,
    Str: []const u8,
    CtBuf: ComptimeBuf,
    Type: InstValueType,

    const Self = @This();

    const INST_STR_CAP = 14;

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
        const ty: InstType = @enumFromInt(bytes[0]);
        const vty: InstValueType = @enumFromInt(bytes[1]);
        var idx: usize = 2;
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
            inline else => return Inst.new(ty, None)
        };
    }

    pub inline fn new(comptime T: type, v: T) Self {
        return switch (T) {
            u8          => .{ .U8 = v },
            i64         => .{ .I64 = v },
            f64         => .{ .F64 = v },
            u64         => .{ .U64 = v },
            void        => .{ .None = {} },
            NaNBox      => .{ .NaN = v },
            ComptimeBuf => .{ .CtBuf = v },
            InstValueType => .{ .Type = v },
            []const u8  => if (v.len > 1) {
                if (v.len - 1 >= STR_CAP) {
                    const cap: usize = if (v.len - 1 >= STACK_CAP) STACK_CAP else STR_CAP;
                    panic("String length: {} is greater than the maximum capacity {}", .{v.len, cap});
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
        std.debug.assert(bytes.len == 10);
        return InstValue.from_bytes(bytes);
    }

    pub inline fn new(typ: InstType, value: InstValue) Self {
        return .{ .type = typ, .value = value };
    }
};
