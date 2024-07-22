const std       = @import("std");
const flag_mod  = @import("flags.zig");
const Inst      = @import("inst.zig").Inst;
const Trap      = @import("trap.zig").Trap;
const NaNBox    = @import("NaNBox.zig").NaNBox;
const VecDeque  = @import("VecDeque.zig").VecDeque;

const Flag      = flag_mod.Flag;
const Flags     = flag_mod.Flags;
const print     = std.debug.print;
const exit      = std.process.exit;
const assert    = std.debug.assert;
const writer    = std.io.getStdOut().writer();

const Allocator = std.mem.Allocator;

pub const DEBUG = false;

pub const Program   = std.ArrayList(Inst);
pub const LabelMap = std.StringHashMap(usize);

pub const Vm = struct {
    lm: LabelMap,
    halt: bool = false,
    alloc: Allocator,
    flags: Flags = Flags.new(),
    stack: VecDeque(NaNBox),
    program: []const Inst,
    ip: usize = 0,

    const Self = @This();

    pub const STR_CAP = 128;
    pub const STACK_CAP = 1024;
    pub const INIT_STACK_CAP = STACK_CAP / 8;

    pub fn new(program: []const Inst, lm: LabelMap, _alloc: Allocator) !Self {
        return .{
            .lm = lm,
            .alloc = _alloc,
            .stack = try VecDeque(NaNBox).initCapacity(_alloc, INIT_STACK_CAP),
            .program = program,
        };
    }

    pub inline fn deinit(self: *Self) void {
        self.lm.deinit();
        self.stack.deinit();
    }

    inline fn get_ip(self: *Self, inst: *const Inst) !usize {
        return switch (inst.value) {
            .U64 => |ip| ip,
            .Str => |str| if (self.lm.get(str)) |ip| ip else return error.UNDEFINED_SYMBOL,
            .Nan => |nan| @intCast(nan.as(i64)),
            else => error.INVALID_TYPE
        };
    }

    inline fn ip_check(self: *Self, ip: usize) !usize {
        if (ip < 0 or ip > self.program.len)
            return error.INVALID_INSTRUCTION_ACCESS;
        return ip;
    }

    fn jmp_if_flag(self: *Self, inst: *const Inst) !void {
        const flag = Flag.from_inst(inst).?;
        if (self.flags.is(flag)) {
            const ip = try self.get_ip(inst);
            self.ip = try self.ip_check(ip);
        } else self.ip += 1;
    }

    inline fn math_op(self: *Self, comptime T: type, a: T, b: T, ptr: *NaNBox, comptime op: u8) !void {
        const v = switch (op) {
            '+' => b + a,
            '-' => b - a,
            '/' => if (T == i64) @divFloor(b, a) else b / a,
            '*' => b * a,
            else => @compileError(std.fmt.comptimePrint("UNEXPECTED OP: {c}", .{op})),
        };
        ptr.* = NaNBox.from(T, v);
        self.ip += 1;
    }

    inline fn perform_mathop(self: *Self, comptime op: u8) !void {
        if (self.stack.len() < 2)
            return error.STACK_UNDERFLOW;

        const a = self.stack.popBack().?;
        const b = self.stack.back().?;

        return switch (a.getType()) {
            .I64 => self.math_op(i64, a.as(i64), b.as(i64), b, op),
            .U64 => self.math_op(u64, a.as(u64), b.as(u64), b, op),
            .F64 => self.math_op(f64, a.as(f64), b.as(f64), b, op),
            else => return error.INVALID_TYPE,
        };
    }

    fn execute_instruction(self: *Self, inst: *const Inst) !void {
        return switch (inst.type) {
            .nop => self.ip += 1,
            .push => if (self.stack.len() < STACK_CAP) {
                try switch (inst.value) {
                    .Nan => |nan| self.stack.pushBack(nan),
                    .F64 => |val| self.stack.pushBack(NaNBox.from(f64, val)),
                    .U64 => |val| self.stack.pushBack(NaNBox.from(u64, val)),
                    .I64 => |val| self.stack.pushBack(NaNBox.from(i64, val)),
                    .Str => |str| {
                        var nans: [STR_CAP]NaNBox = undefined;
                        for (str, 0..) |byte, i|
                            nans[i] = NaNBox.from(u8, byte);

                        try self.stack.appendSlice(nans[0..str.len]);
                        try self.stack.pushBack(NaNBox.from([]const u8, str));
                    },
                    else => return error.INVALID_TYPE,
                };
                self.ip += 1;
            } else return error.STACK_OVERFLOW,
            .pop => if (self.stack.len() > 0) {
                const n = self.stack.len();
                switch (self.stack.buf[n - 1].getType()) {
                    .Str => {
                        if (n < 1) return error.STACK_UNDERFLOW;
                        const nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), @intCast(self.stack.buf[n - 1].as(u8) - 1)), .Str);
                        self.stack.get(n - 2).?.* = .{.v = nan};
                        _ = self.stack.popBack();
                    },
                    else => _ = self.stack.popBack(),
                }
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .swap => switch (inst.value) {
                .U64 => |idx_| if (self.stack.len() > idx_) {
                    const len = self.stack.len();
                    const idx = len - idx_ - 1;
                    self.stack.swap(idx, len - 1);
                    self.ip += 1;
                } else return error.STACK_UNDERFLOW,
                else => return error.INVALID_TYPE
            },
            .dup => switch (inst.value) {
                .U64 => |idx_| if (self.stack.len() > idx_) {
                    const idx = self.stack.len() - idx_ - 1;
                    const nth = self.stack.get(idx).?.*;
                    try self.stack.pushBack(nth);
                    self.ip += 1;
                } else return error.STACK_UNDERFLOW,
                else => return error.INVALID_TYPE
            },
            .inc => if (self.stack.len() > 0) {
                const nan = self.stack.back().?;
                nan.* =  switch (nan.getType()) {
                    .U64 => NaNBox.from(u64, nan.as(u64) + 1),
                    .I64 => NaNBox.from(i64, nan.as(i64) + 1),
                    .F64 => NaNBox.from(f64, nan.as(f64) + 1.0),
                    else => return error.INVALID_TYPE
                };
                self.ip += 1;
            },
            .dec => if (self.stack.len() > 0) {
                const nan = self.stack.back().?;
                nan.* =  switch (nan.getType()) {
                    .U64 => NaNBox.from(u64, nan.as(u64) - 1),
                    .I64 => NaNBox.from(i64, nan.as(i64) - 1),
                    .F64 => NaNBox.from(f64, nan.as(f64) - 1.0),
                    else => return error.INVALID_TYPE
                };
                self.ip += 1;
            },

            .je, .jne, .jg, .jl, .jle, .jge => self.jmp_if_flag(inst),
            .jmp => {
                const ip = try self.get_ip(inst);
                self.ip = try self.ip_check(ip);
            },

            .dmp => if (self.stack.back()) |v| {
                switch (v.getType()) {
                    .I64, .U64, .F64, .U8 => {
                        var buf: [32]u8 = undefined;
                        const ret = try std.fmt.bufPrint(&buf, "{}\n", .{v});
                        _ = writer.write(ret) catch |err| {
                            std.log.err("Failed to write to stdout: {}", .{err});
                            exit(1);
                        };
                    },
                    .Str => if (self.stack.len() > v.as(i64)) {
                        const len: usize = @intCast(v.as(i64));
                        const nans = self.stack.buf[self.stack.len() - 1 - len..self.stack.len() - 1];
                        var bytes: [STR_CAP + 1]u8 = undefined;
                        for (nans, 0..) |nan, i|
                            bytes[i] = nan.as(u8);

                        bytes[len] = '\n';
                        _ = writer.write(bytes[0..len + 1]) catch |err| {
                            std.log.err("Failed to write to stdout: {}", .{err});
                            exit(1);
                        };
                    } else return error.STACK_UNDERFLOW,
                }
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .iadd => try self.perform_mathop('+'),
            .isub => try self.perform_mathop('-'),
            .idiv => try self.perform_mathop('/'),
            .imul => try self.perform_mathop('*'),
            .fadd => try self.perform_mathop('+'),
            .fsub => try self.perform_mathop('-'),
            .fdiv => try self.perform_mathop('/'),
            .fmul => try self.perform_mathop('*'),
            .cmp => if (self.stack.len() > 1) {
                const a = self.stack.get(self.stack.len() - 2).?;
                const b = self.stack.popBack().?;

                switch (a.getType()) {
                    .I64 => self.flags.cmp(i64, a.as(i64), b.as(i64)),
                    .U64 => self.flags.cmp(u64, a.as(u64), b.as(u64)),
                    .F64 => self.flags.cmp(f64, a.as(f64), b.as(f64)),
                    else => return error.INVALID_TYPE
                }

                if (DEBUG) {
                    print("IS E:  {}\n", .{self.flags.is(Flag.E)});
                    print("IS NE: {}\n", .{self.flags.is(Flag.NE)});
                    print("IS G:  {}\n", .{self.flags.is(Flag.G)});
                    print("IS L:  {}\n", .{self.flags.is(Flag.L)});
                    print("IS LE: {}\n", .{self.flags.is(Flag.LE)});
                    print("IS GE: {}\n", .{self.flags.is(Flag.GE)});
                }

                self.ip += 1;
            },
            .halt => self.halt = true,
            .label => self.ip += 1
        };
    }

    pub fn execute_program(self: *Self) !void {
        while (!self.halt and self.ip < self.program.len) {
            const inst = self.program[self.ip];
            if (DEBUG) print("{} : {}\n", .{self.stack, inst.type});
            try self.execute_instruction(&inst);
        }
    }
};
