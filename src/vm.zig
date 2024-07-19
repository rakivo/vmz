const std       = @import("std");

const flag_mod  = @import("flags.zig");

const Inst      = @import("inst.zig").Inst;
const Trap      = @import("trap.zig").Trap;
const NaNBox    = @import("NaNBox.zig").NaNBox;
const VecDeque  = @import("VecDeque.zig").VecDeque;

const Flag      = flag_mod.Flag;
const Flags     = flag_mod.Flags;
const writer    = std.io.getStdOut().writer();
const print     = std.debug.print;
const assert    = std.debug.assert;

const Program   = std.ArrayList(Inst);
const Allocator = std.mem.Allocator;

const DEBUG = false;

pub const Vm = struct {
    flags: Flags = Flags.new(),
    stack: VecDeque(NaNBox),
    program: []const Inst,
    ip: usize = 0,

    const Self = @This();

    pub const STR_CAP = 128;
    pub const STACK_CAP = 1024;

    const ALLOCATOR = std.heap.page_allocator;

    pub inline fn new(_program: []const Inst) !Self {
        return .{
            .stack = try VecDeque(NaNBox).initCapacity(ALLOCATOR, STACK_CAP),
            .program = _program,
        };
    }

    pub inline fn deinit(self: Self) void {
        self.stack.deinit();
    }

    pub inline fn jmp_if_flag(self: *Self, inst: *const Inst) !void {
        const flag = Flag.from_inst(inst).?;
        if (self.flags.is(flag)) {
            self.ip = switch (inst.value) {
                .U64 => |ip| ip,
                .Nan => |nan| nan.as(u64),
                else => return error.INVALID_TYPE
            };
        } else self.ip += 1;
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
                _ = self.stack.popBack();
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .swap => switch (inst.value) {
                .U64 => |idx_| if (self.stack.len() > idx_) {
                    const back = self.stack.back().?;
                    const idx = self.stack.len() - idx_ - 1;
                    const nth = self.stack.get(idx).?;
                    const t = nth.*;
                    nth.* = back.*;
                    back.* = t;
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

            .je,
            .jne,
            .jg,
            .jl,
            .jle,
            .jge => self.jmp_if_flag(inst),

            .dmp => if (self.stack.back()) |v| {
                switch (v.getType()) {
                    .I64, .U64, .F64, .U8 => print("{d}\n", .{v}),
                    .Str => if (self.stack.len() > v.as(usize)) {
                        const len = v.as(usize);
                        const nans = self.stack.buf[self.stack.len() - 1 - len .. self.stack.len() - 1];

                        // I mean we can go the heap way but it feels redundant

                        // const start = self.stack.len() - 1 - len;
                        // const end = self.stack.len() - 1;

                        // var buf = try std.ArrayList(u8).initCapacity(ALLOCATOR, end - start);
                        // for (nans) |nan|
                        //     try buf.append(nan.as(u8));

                        // print("{s}\n", .{buf.items});

                        var bytes: [STR_CAP + 1]u8 = undefined;
                        for (nans, 0..) |nan, i|
                            bytes[i] = nan.as(u8);

                        bytes[len] = '\n';
                        const n = writer.write(bytes[0..len + 1]) catch |err| {
                            std.log.err("Failed to write to stdout: {}", .{err});
                            unreachable;
                        };

                        // This certainly should not happen
                        assert(n == len + 1);
                    },
                }
                self.ip += 1;
            },
            .iadd => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?;
                const b = self.stack.back().?;
                const t = b.*;
                if (a.is(i64) and t.is(i64)) {
                    b.* = NaNBox.from(i64, a.as(i64) + t.as(i64));
                } else if (a.is(u64) and t.is(u64)) {
                    b.* = NaNBox.from(u64, a.as(u64) + t.as(u64));
                } else return error.INVALID_TYPE;
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .isub => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?;
                const b = self.stack.back().?;
                const t = b.*;
                if (a.is(i64) and t.is(i64)) {
                    b.* = NaNBox.from(i64, a.as(i64) - t.as(i64));
                } else if (a.is(u64) and t.is(u64)) {
                    b.* = NaNBox.from(u64, a.as(u64) - t.as(u64));
                } else return error.INVALID_TYPE;
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .idiv => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?;
                const b = self.stack.back().?;
                const t = b.*;
                if (a.is(i64) and t.is(i64)) {
                    b.* = NaNBox.from(i64, @divFloor(a.as(i64), t.as(i64)));
                } else if (a.is(u64) and t.is(u64)) {
                    b.* = NaNBox.from(u64, @divFloor(a.as(u64), t.as(u64)));
                } else return error.INVALID_TYPE;
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .imul => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?;
                const b = self.stack.back().?;
                const t = b.*;
                if (a.is(i64) and t.is(i64)) {
                    b.* = NaNBox.from(i64, a.as(i64) * t.as(i64));
                } else if (a.is(u64) and t.is(u64)) {
                    b.* = NaNBox.from(u64, a.as(u64) * t.as(u64));
                } else return error.INVALID_TYPE;
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .fadd => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?;
                const b = self.stack.back().?;
                const t = b.*;
                if (a.is(f64) and t.is(f64)) {
                    b.* = NaNBox.from(f64, b.as(f64) + a.as(f64));
                    self.ip += 1;
                } else return error.INVALID_TYPE;
            } else return error.STACK_UNDERFLOW,
            .fsub => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?;
                const b = self.stack.back().?;
                const t = b.*;
                if (a.is(f64) and t.is(f64)) {
                    b.* = NaNBox.from(f64, b.as(f64) - a.as(f64));
                    self.ip += 1;
                } else return error.INVALID_TYPE;
            } else return error.STACK_UNDERFLOW,
            .fdiv => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?;
                const b = self.stack.back().?;
                const t = b.*;
                if (a.is(f64) and t.is(f64)) {
                    b.* = NaNBox.from(f64, b.as(f64) / a.as(f64));
                    self.ip += 1;
                } else return error.INVALID_TYPE;
            } else return error.STACK_UNDERFLOW,
            .fmul => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?;
                const b = self.stack.back().?;
                const t = b.*;
                if (a.is(f64) and t.is(f64)) {
                    b.* = NaNBox.from(f64, b.as(f64) * a.as(f64));
                    self.ip += 1;
                } else return error.INVALID_TYPE;
            } else return error.STACK_UNDERFLOW,
            .cmp => if (self.stack.len() > 1) {
                const a_ = self.stack.get(self.stack.len() - 2).?;
                const b_ = self.stack.popBack().?;

                const a: i64 = if (a_.is(u64)) @intCast(a_.as(u64))
                else if (a_.is(i64)) a_.as(i64)
                else return error.INVALID_TYPE;

                const b: i64 = if (b_.is(u64)) @intCast(b_.as(u64))
                else if (b_.is(i64)) b_.as(i64)
                else return error.INVALID_TYPE;

                self.flags.cmp(a, b);

                if (DEBUG) {
                    print("IS E:  {}\n", .{self.flags.is(Flag.E)});
                    print("IS NE: {}\n", .{self.flags.is(Flag.NE)});
                    print("IS G:  {}\n", .{self.flags.is(Flag.G)});
                    print("IS L:  {}\n", .{self.flags.is(Flag.L)});
                    print("IS LE: {}\n", .{self.flags.is(Flag.LE)});
                    print("IS GE: {}\n", .{self.flags.is(Flag.GE)});
                }

                self.ip += 1;
            }
        };
    }

    pub fn execute_program(self: *Self) !void {
        while (self.ip < self.program.len) {
            if (DEBUG) print("STACK: {}\n", .{self.stack});
            const inst = self.program[self.ip];
            try self.execute_instruction(&inst);
        }
    }
};
