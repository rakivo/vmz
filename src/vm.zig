const std       = @import("std");

const Inst      = @import("inst.zig").Inst;
const Trap      = @import("trap.zig").Trap;
const NaNBox    = @import("NaNBox.zig").NaNBox;
const VecDeque  = @import("VecDeque.zig").VecDeque;

const writer    = std.io.getStdOut().writer();
const print     = std.debug.print;
const assert    = std.debug.assert;

const Program   = std.ArrayList(Inst);
const Allocator = std.mem.Allocator;

const DEBUG = false;

pub const program = struct {
    pub fn new(insts: []const Inst) !Program {
        var program_ = std.ArrayList(Inst).init(Vm.ALLOCATOR);
        try program_.appendSlice(insts);
        return program_;
    }
};

pub const Vm = struct {
    stack: VecDeque(NaNBox),
    program: []const Inst,
    flags: bool = false,
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

    fn execute_instruction(self: *Self, inst: *const Inst) !void {
        return switch (inst.ty) {
            .push => if (self.stack.len() < STACK_CAP) {
                try switch (inst.v) {
                    .Nan => |nan| self.stack.pushBack(nan),
                    .F64 => |val| self.stack.pushBack(NaNBox.from(f64, val)),
                    .U64 => |val| self.stack.pushBack(NaNBox.from(u64, val)),
                    .I64 => |val| self.stack.pushBack(NaNBox.from(i64, val)),
                    .Str => |str| {
                        if (str.len - 1 >= STR_CAP) {
                            const cap: usize = if (str.len - 1 >= STACK_CAP) STACK_CAP else STR_CAP;
                            print("String length: {} is greater than the maximum capacity: {}\n", .{str.len, cap});
                            unreachable;
                        }

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
            .add => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?.as(u64);
                const b = self.stack.back().?;
                const t = b.as(u64);
                b.* = NaNBox.from(u64, a + t);
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .swap => switch (inst.v) {
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
            .dup => switch (inst.v) {
                .U64 => |idx_| if (self.stack.len() > idx_) {
                    const idx = self.stack.len() - idx_ - 1;
                    const nth = self.stack.get(idx).?.*;
                    try self.stack.pushBack(nth);
                    self.ip += 1;
                } else return error.STACK_UNDERFLOW,
                else => return error.INVALID_TYPE
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
            .jne => switch (inst.v) {
                .U64 => |ip| if (self.program.len > ip and self.flags) {
                    self.ip = ip;
                } else { self.ip += 1; },
                else => return error.INVALID_TYPE
            },
            .dmp => if (self.stack.back()) |v| {
                switch (v.getType()) {
                    .I64, .U64, .F64, .U8 => print("{d}\n", .{v}),
                    .Str => if (self.stack.len() > v.as(usize)) {
                        const len = v.as(usize);
                        const nans = self.stack.buf[self.stack.len() - 1 - len .. self.stack.len() - 1];

                        // I mean we can go the heap way but it feels redundant
                        //
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
            .fadd => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?;
                const b = self.stack.back().?;
                const t = b.*;
                assert(a.is(f64) and t.is(f64));
                b.* = NaNBox.from(f64, b.as(f64) + a.as(f64));
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .fsub => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?;
                const b = self.stack.back().?;
                const t = b.*;
                assert(a.is(f64) and t.is(f64));
                b.* = NaNBox.from(f64, b.as(f64) - a.as(f64));
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .fdiv => if (self.stack.len() > 1) {
                const a = self.stack.popBack().?;
                const b = self.stack.back().?;
                const t = b.*;
                assert(a.is(f64) and t.is(f64));
                b.* = NaNBox.from(f64, b.as(f64) / a.as(f64));
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            // Umm I'm to lazy now to add proper flags support.
            .cmp => if (self.stack.len() > 1) {
                self.flags = false;
                const a = self.stack.get(self.stack.len() - 2).?;
                const b = self.stack.popBack().?;
                if (a.as(u64) != b.as(u64)) self.flags = true;
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
