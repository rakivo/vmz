const std      = @import("std");
const builtin  = @import("builtin");
const flag_mod = @import("flags.zig");
const Heap     = @import("heap.zig").Heap;
const Loc      = @import("lexer.zig").Token.Loc;
const Inst     = @import("inst.zig").Inst;
const Trap     = @import("trap.zig").Trap;
const Natives  = @import("natives.zig").Natives;
const NaNBox   = @import("NaNBox.zig").NaNBox;
const VecDeque = @import("VecDeque.zig").VecDeque;
const Parsed   = @import("parser.zig").Parser.Parsed;

const Flag  = flag_mod.Flag;
const Flags = flag_mod.Flags;

const print  = std.debug.print;
const exit   = std.process.exit;
const assert = std.debug.assert;
const writer = std.io.getStdOut().writer();

pub const Program  = std.ArrayList(Inst);
pub const LabelMap = std.StringHashMap(u32);
pub const InstMap  = std.AutoHashMap(u32, Loc);

pub const DEBUG = true;

pub const Vm = struct {
    hp: u64 = 128,
    halt: bool = false,
    flags: Flags = Flags.new(),

    ip: u64,
    lm: *const LabelMap,
    im: *const InstMap,
    natives: *const Natives,
    program: []const Inst,
    alloc: std.mem.Allocator,

    heap: Heap,
    call_stack: VecDeque(u64),
    stack: VecDeque(NaNBox),

    const Self = @This();

    pub const STR_CAP = 128;

    pub const STACK_CAP = 1024;
    pub const INIT_STACK_CAP = STACK_CAP / 8;

    pub const CALL_STACK_CAP = 1024;
    pub const INIT_CALL_STACK_CAP = STACK_CAP / 8;

    pub inline fn init(parsed: *Parsed, natives: *const Natives, alloc: std.mem.Allocator) !Self {
        return .{
            .lm = &parsed.lm,
            .im = &parsed.im,
            .ip = parsed.ip,
            .alloc = alloc,
            .program = parsed.program.items,
            .natives = natives,
            .heap = try Heap.init(alloc),
            .call_stack = try VecDeque(u64).initCapacity(alloc, INIT_CALL_STACK_CAP),
            .stack = try VecDeque(NaNBox).initCapacity(alloc, INIT_STACK_CAP),
        };
    }

    pub inline fn deinit(self: *Self) void {
        self.heap.deinit();
        self.stack.deinit();
    }

    inline fn get_ip(self: *Self, inst: *const Inst) !usize {
        return switch (inst.value) {
            .U64 => |ip| ip,
            .Str => |str| if (self.lm.get(str)) |ip| ip else return error.UNDEFINED_SYMBOL,
            .NaN => |nan| @intCast(nan.as(i64)),
            else => error.INVALID_TYPE
        };
    }

    inline fn ip_check(self: *Self, ip: usize) !usize {
        if (ip < 0 or ip > self.program.len)
            return error.ILLEGAL_INSTRUCTION_ACCESS;

        return ip;
    }

    inline fn jmp_if_flag(self: *Self, inst: *const Inst) !void {
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

    inline fn report_err(self: *const Self, err: anyerror) anyerror {
        const loc = self.im.get(@intCast(self.ip)).?;
        std.debug.print("{s}:{d}:{d}: ERROR: {}\n", .{
            loc.file_path,
            loc.row + 1,
            loc.col + 1,
            err,
        });
        if (builtin.mode == .Debug) {
            return err;
        } else exit(1);
    }

    inline fn get_int(inst: *const Inst) !i64 {
        return switch (inst.value) {
            .NaN => |nan| return switch (nan.getType()) {
                .U64 => @intCast(nan.as(u64)),
                .I64 => nan.as(i64),
                else => error.INVALID_TYPE,
            },
            .U64 => |int| @intCast(int),
            .I64 => |int| int,
            else => error.INVALID_TYPE,
        };
    }

    inline fn get_uint(inst: *const Inst) !u64 {
        return @intCast(try get_int(inst));
    }

    fn execute_instruction(self: *Self, inst: *const Inst) !void {
        return switch (inst.type) {
            .nop => self.ip += 1,
            .call => if (self.call_stack.len() + 1 < CALL_STACK_CAP) {
                const ip = try self.ip_check(try self.get_ip(inst));
                if (ip + 1 > self.program.len)
                    return error.ILLEGAL_INSTRUCTION_ACCESS;

                try self.call_stack.pushBack(self.ip + 1);
                self.ip = ip;
            } else return error.CALL_STACK_OVERFLOW,
            .ret => if (self.call_stack.len() > 0) {
                self.ip = self.call_stack.popBack().?;
            } else return error.CALL_STACK_UNDERFLOW,
            .alloc => if (self.hp < Heap.CAP) {
                var len = try get_uint(inst);
                if (len > self.hp) {
                    while (len > 0) {
                        const cap_inc = (self.heap.cap * 2 - self.heap.cap);
                        if (cap_inc > len) {
                            break;
                        } else len -= cap_inc;
                        self.hp += cap_inc;
                        try self.heap.grow();
                    }
                }
                self.ip += 1;
            } else return error.FAILED_TO_GROW,
            .push => if (self.stack.len() < STACK_CAP) {
                try switch (inst.value) {
                    .U8  => |chr| self.stack.pushBack(NaNBox.from(u8, chr)),
                    .NaN => |nan| self.stack.pushBack(nan),
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
            .spush => if (self.stack.len() < STACK_CAP) {
                try switch (inst.value) {
                    .U8 => |chr| {
                        _ = blk: {
                            if (self.stack.back()) |back| {
                                if (back.getType() == .U8) {
                                    const str = &[_]u8 {back.as(u8), chr};
                                    try self.stack.pushBack(NaNBox.from(u8, chr));
                                    try self.stack.pushBack(NaNBox.from([]const u8, str));
                                    self.ip += 1;
                                    return;
                                } else if (back.getType() != .Str) break :blk;
                                const new_str_len = back.as(u64) + 1;
                                back.* = NaNBox.from(u8, chr);
                                const new_str_len_nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), @intCast(new_str_len)), .Str);
                                try self.stack.pushBack(NaNBox {.v = new_str_len_nan});
                            } else break :blk;
                        };
                        try self.stack.pushBack(NaNBox.from(u8, chr));
                    },
                    .NaN => |nan| self.stack.pushBack(nan),
                    .F64 => |val| self.stack.pushBack(NaNBox.from(f64, val)),
                    .U64 => |val| self.stack.pushBack(NaNBox.from(u64, val)),
                    .I64 => |val| self.stack.pushBack(NaNBox.from(i64, val)),
                    .Str => |str| {
                        _ = blk: {
                            if (self.stack.back()) |back| {
                                if (back.getType() != .Str) break :blk;
                                const new_str_len = back.as(u64) + str.len;
                                back.* = NaNBox.from(u8, str[0]);
                                for (1..str.len) |i|
                                    try self.stack.pushBack(NaNBox.from(u8, str[i]));

                                const new_str_len_nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), @intCast(new_str_len)), .Str);
                                try self.stack.pushBack(NaNBox {.v = new_str_len_nan});
                            } else
                                break :blk;

                            self.ip += 1;
                            return;
                        };

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
            .spop => if (self.stack.len() > 0) {
                const n = self.stack.len();
                switch (self.stack.buf[n - 1].getType()) {
                    .Str => {
                        if (n < 1) return error.STACK_UNDERFLOW;
                        var str_len = self.stack.popBack().?.as(u64);
                        while (str_len > 0) {
                            str_len -= 1;
                            _ = self.stack.popBack();
                        }
                    },
                    else => _ = self.stack.popBack(),
                }
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .pop => if (self.stack.len() > 0) {
                const n = self.stack.len();
                switch (self.stack.buf[n - 1].getType()) {
                    .Str => {
                        if (n < 1) return error.STACK_UNDERFLOW;
                        const nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), self.stack.buf[n - 1].as(i64) - 1), .Str);
                        self.stack.get(n - 2).?.* = .{.v = nan};
                        _ = self.stack.popBack();
                    },
                    else => _ = self.stack.popBack(),
                }
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
            .swap => return switch (inst.value) {
                .U64 => |idx_| if (self.stack.len() > idx_) {
                    const len = self.stack.len();
                    const idx = len - idx_ - 1;
                    self.stack.swap(idx, len - 1);
                    self.ip += 1;
                } else return error.STACK_UNDERFLOW,
                else => return error.INVALID_TYPE
            },
            .dup => return switch (inst.value) {
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
                nan.* = switch (nan.getType()) {
                    .U64 => NaNBox.from(u64, nan.as(u64) + 1),
                    .I64 => NaNBox.from(i64, nan.as(i64) + 1),
                    .F64 => NaNBox.from(f64, nan.as(f64) + 1.0),
                    else => return error.INVALID_TYPE
                };
                self.ip += 1;
            },
            .dec => if (self.stack.len() > 0) {
                const nan = self.stack.back().?;
                nan.* = switch (nan.getType()) {
                    .U64 => NaNBox.from(u64, nan.as(u64) - 1),
                    .I64 => NaNBox.from(i64, nan.as(i64) - 1),
                    .F64 => NaNBox.from(f64, nan.as(f64) - 1.0),
                    else => return error.INVALID_TYPE
                };
                self.ip += 1;
            },
            .je, .jne, .jg, .jl, .jle, .jge => self.jmp_if_flag(inst),
            .jmp => self.ip = try self.ip_check(try self.get_ip(inst)),
            .dmp => if (self.stack.back()) |v| {
                switch (v.getType()) {
                    .U8 => {
                        _ = writer.write(&[_]u8 {v.as(u8), 10}) catch |err| {
                            std.log.err("Failed to write to stdout: {}", .{err});
                            exit(1);
                        };
                    },
                    .I64, .U64, .F64 => {
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

                self.ip += 1;
            },
            .halt => self.halt = true,
            .native => {
                const name = switch (inst.value) {
                    .Str => |str| str,
                    else => return error.INVALID_TYPE,
                };
                const ptro = self.natives.get(name);
                if (ptro) |ptr| {
                    try ptr(self);
                } else {
                    if (self.natives.map.count() > 0) {
                        var it = self.natives.map.keyIterator();
                        print("Names of natives provided: {s}\n", .{it.next().?.*});
                        while (it.next()) |key|
                            print(", {s}\n", .{key.*});
                    }
                    return error.UNDEFINED_SYMBOL;
                }

                self.ip += 1;
            },
            .label => self.ip += 1
        };
    }

    pub fn execute_program(self: *Self) !void {
        while (!self.halt and self.ip < self.program.len) {
            const inst = self.program[self.ip];
            if (DEBUG) print("{}: {}\n", .{self.stack, inst});
            self.execute_instruction(&inst) catch |err| {
                return self.report_err(err);
            };
        }
    }
};
