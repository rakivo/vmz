const std      = @import("std");

const Inst     = @import("inst.zig").Inst;
const Trap     = @import("trap.zig").Trap;
const NaNBox   = @import("NaNBox.zig").NaNBox;
const VecDeque = @import("VecDeque.zig").VecDeque;

const print     = std.debug.print;
const assert    = std.debug.assert;
const Program   = std.ArrayList(Inst);
const Allocator = std.mem.Allocator;

pub const program = struct {
    pub fn new(alloc: Allocator, insts: []const Inst) !Program {
        var program_ = std.ArrayList(Inst).init(alloc);
        try program_.appendSlice(insts);
        return program_;
    }
};

pub const Vm = struct {
    stack: VecDeque(NaNBox),
    program: Program,
    flags: bool = false,
    ip: usize = 0,

    const Self = @This();
    const STACK_CAP = 1024;
    const ALLOCATOR = std.heap.page_allocator;

    pub inline fn new(_program: Program) !Self {
        return .{
            .stack = try VecDeque(NaNBox).init(ALLOCATOR),
            .program = _program,
        };
    }

    pub inline fn deinit(self: Self) void {
        self.stack.deinit();
        self.program.deinit();
    }

    fn execute_instruction(self: *Self, inst: *const Inst) !void {
        return switch (inst.ty) {
            .push => if (self.stack.len() < STACK_CAP) {
                try switch (inst.v) {
                    .Nan => |nan| self.stack.pushBack(nan),
                    .F64 => |val| self.stack.pushBack(NaNBox.from(f64, val)),
                    .U64 => |val| self.stack.pushBack(NaNBox.from(u64, val)),
                    .I64 => |val| self.stack.pushBack(NaNBox.from(i64, val)),
                    else => {}
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
                else => {}
            },
            .dup => switch (inst.v) {
                .U64 => |idx_| if (self.stack.len() > idx_) {
                    const idx = self.stack.len() - idx_ - 1;
                    const nth = self.stack.get(idx).?.*;
                    try self.stack.pushBack(nth);
                    self.ip += 1;
                } else return error.STACK_UNDERFLOW,
                else => {}
            },
            .dec => if (self.stack.len() > 0) {
                const nan = self.stack.back().?;
                nan.* =  switch (nan.getType()) {
                    .U64 => NaNBox.from(u64, nan.as(u64) - 1),
                    .I64 => NaNBox.from(i64, nan.as(i64) - 1),
                    .F64 => NaNBox.from(f64, nan.as(f64) - 1.0),
                };
                self.ip += 1;
            },
            .jne => switch (inst.v) {
                .U64 => |ip| if (self.program.items.len > ip and self.flags) {
                    self.ip = ip;
                } else { self.ip += 1; },
                else => {}
            },
            .dmp => if (self.stack.popBack()) |last| {
                print("{d}\n", .{last});
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
        while (self.ip < self.program.items.len) {
            const inst = self.program.items[self.ip];
            try self.execute_instruction(&inst);
        }
    }
};
