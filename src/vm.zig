const std      = @import("std");
const builtin  = @import("builtin");
const inst_mod = @import("inst.zig");
const flag_mod = @import("flags.zig");
const lexer    = @import("lexer.zig");
const Heap     = @import("heap.zig").Heap;
const Trap     = @import("trap.zig").Trap;
const NaNBox   = @import("NaNBox.zig").NaNBox;
const Natives  = @import("natives.zig").Natives;
const VecDeque = @import("VecDeque.zig").VecDeque;
const Parsed   = @import("parser.zig").Parser.Parsed;

const Inst = inst_mod.Inst;
const InstValue = inst_mod.InstValue;

const Loc = lexer.Token.Loc;

const Flag  = flag_mod.Flag;
const Flags = flag_mod.Flags;

const print  = std.debug.print;
const exit   = std.process.exit;
const assert = std.debug.assert;

const rstdin = std.io.getStdOut().reader();
const wstdin = std.io.getStdOut().writer();

const rstdout = std.io.getStdOut().reader();
const wstdout = std.io.getStdOut().writer();

const rstderr = std.io.getStdOut().reader();
const wstderr = std.io.getStdOut().writer();

pub const Program  = std.ArrayList(Inst);
pub const LabelMap = std.StringHashMap(u32);
pub const InstMap  = std.AutoHashMap(u32, Loc);

pub const DEBUG = false;

pub const Vm = struct {
    mp: u64 = 0,
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
    stack: VecDeque(NaNBox),
    call_stack: VecDeque(u64),
    memory: [MEMORY_CAP]u8 = undefined,

    const Self = @This();

    pub const STR_CAP = 128;

    pub const MEMORY_CAP = 1024 * 8;

    pub const STACK_CAP = 1024;
    pub const INIT_STACK_CAP = STACK_CAP / 8;

    pub const CALL_STACK_CAP = 1024;
    pub const INIT_CALL_STACK_CAP = STACK_CAP / 8;

    pub const READ_BUF_CAP = 1024;

    pub inline fn init(parsed: *Parsed, natives: *const Natives, alloc: std.mem.Allocator) !Self {
        return .{
            .alloc = alloc,
            .ip = parsed.ip,
            .lm = &parsed.lm,
            .im = &parsed.im,
            .natives = natives,
            .heap = try Heap.init(alloc),
            .program = parsed.program.items,
            .stack = try VecDeque(NaNBox).initCapacity(alloc, INIT_STACK_CAP),
            .call_stack = try VecDeque(u64).initCapacity(alloc, INIT_CALL_STACK_CAP),
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

    fn report_err(self: *const Self, err: anyerror) anyerror {
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

    inline fn get_int(inst: *const Inst) ?i64 {
        return switch (inst.value) {
            .NaN => |nan| return switch (nan.getType()) {
                .U64 => @intCast(nan.as(u64)),
                .I64 => nan.as(i64),
                else => null,
            },
            .U64 => |int| @intCast(int),
            .I64 => |int| int,
            else => null,
        };
    }

    inline fn get_uint(inst: *const Inst) ?u64 {
        return if (get_int(inst)) |some| @intCast(some) else null;
    }

    fn print_value(self: *Self, v: *const NaNBox, newline: bool) !void {
        switch (v.getType()) {
            .U8 => {
                const buf = if (newline) &[_]u8 {v.as(u8), 10} else &[_]u8 {v.as(u8)};
                _ = wstdout.write(buf) catch |err| {
                    std.log.err("Failed to write to stdout: {}", .{err});
                    exit(1);
                };
            },
            .I64, .U64, .F64 => {
                var buf: [32]u8 = undefined;
                var ret: []u8 = undefined;
                if (newline) {
                    ret = try std.fmt.bufPrint(&buf,  "{}\n", .{v});
                } else {
                    ret = try std.fmt.bufPrint(&buf,  "{}", .{v});
                }
                _ = wstdout.write(ret) catch |err| {
                    std.log.err("Failed to write to stdout: {}", .{err});
                    exit(1);
                };
            },
            .Str => if (self.stack.len() > v.as(u64)) {
                const len = v.as(u64);
                const stack_len = self.stack.len();
                const nans = self.stack.buf[stack_len - 1 - len..stack_len];
                var str: [STR_CAP + 1]u8 = undefined;
                var i: usize = 0;
                while (i < nans.len) : (i += 1)
                    str[i] = nans[i].as(u8);

                if (newline) str[i - 1] = 10;
                _ = wstdout.write(str[0..i]) catch |err| {
                    std.log.err("Failed to write to stdout: {}", .{err});
                    exit(1);
                };
            }
            else return error.STACK_UNDERFLOW,
        }
    }

    fn execute_instruction(self: *Self, inst: *const Inst) !void {
        return switch (inst.type) {
            .push => return if (self.stack.len() < STACK_CAP) {
                defer self.ip += 1;
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
            } else error.STACK_OVERFLOW,
            .pop => return if (self.stack.len() > 0) {
                const n = self.stack.len();
                defer self.ip += 1;
                switch (self.stack.buf[n - 1].getType()) {
                    .Str => {
                        if (n < 1) return error.STACK_UNDERFLOW;
                        const nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), self.stack.buf[n - 1].as(i64) - 1), .Str);
                        self.stack.get(n - 2).?.* = .{.v = nan};
                        _ = self.stack.popBack();
                    },
                    else => _ = self.stack.popBack(),
                }
            } else error.STACK_UNDERFLOW,
            .swap => return if (get_uint(inst)) |uint| {
                const len = self.stack.len();
                if (len > uint) {
                    const idx = len - uint - 1;
                    self.stack.swap(idx, len - 1);
                    self.ip += 1;
                } else return error.STACK_UNDERFLOW;
            } else error.INVALID_TYPE,
            .dup => return switch (inst.value) {
                .U64 => |idx_| if (self.stack.len() > idx_) {
                    const idx = self.stack.len() - idx_ - 1;
                    const nth = self.stack.get(idx).?.*;
                    try self.stack.pushBack(nth);
                    self.ip += 1;
                } else return error.STACK_UNDERFLOW,
                else => return error.INVALID_TYPE
            },
            .inc => return if (self.stack.len() > 0) {
                const nan = self.stack.back().?;
                nan.* = switch (nan.getType()) {
                    .U8  => NaNBox.from(u8, nan.as(u8) + 1),
                    .U64 => NaNBox.from(u64, nan.as(u64) + 1),
                    .I64 => NaNBox.from(i64, nan.as(i64) + 1),
                    .F64 => NaNBox.from(f64, nan.as(f64) + 1.0),
                    else => return error.INVALID_TYPE
                };
                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .dec => return if (self.stack.len() > 0) {
                const nan = self.stack.back().?;
                nan.* = switch (nan.getType()) {
                    .U64 => NaNBox.from(u64, nan.as(u64) - 1),
                    .I64 => NaNBox.from(i64, nan.as(i64) - 1),
                    .F64 => NaNBox.from(f64, nan.as(f64) - 1.0),
                    else => return error.INVALID_TYPE
                };
                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .je, .jne, .jg, .jl, .jle, .jge => self.jmp_if_flag(inst),
            .jmp => self.ip = try self.ip_check(try self.get_ip(inst)),
            .dmpln => return if (self.stack.back()) |v| {
                try self.print_value(v, true);
                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .dmp => return if (self.stack.back()) |v| {
                try self.print_value(v, false);
                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .iadd => try self.perform_mathop('+'),
            .isub => try self.perform_mathop('-'),
            .idiv => try self.perform_mathop('/'),
            .imul => try self.perform_mathop('*'),
            .fadd => try self.perform_mathop('+'),
            .fsub => try self.perform_mathop('-'),
            .fdiv => try self.perform_mathop('/'),
            .fmul => try self.perform_mathop('*'),
            .cmp => return if (self.stack.len() > 1) {
                const a = self.stack.get(self.stack.len() - 2).?;
                const b = self.stack.popBack().?;

                defer self.ip += 1;
                switch (a.getType()) {
                    .I64 => self.flags.cmp(i64, a.as(i64), b.as(i64)),
                    .U64 => self.flags.cmp(u64, a.as(u64), b.as(u64)),
                    .F64 => self.flags.cmp(f64, a.as(f64), b.as(f64)),
                    else => return error.INVALID_TYPE
                }

                // if (DEBUG) {
                //     print("IS E:  {}\n", .{self.flags.is(Flag.E)});
                //     print("IS NE: {}\n", .{self.flags.is(Flag.NE)});
                //     print("IS G:  {}\n", .{self.flags.is(Flag.G)});
                //     print("IS L:  {}\n", .{self.flags.is(Flag.L)});
                //     print("IS LE: {}\n", .{self.flags.is(Flag.LE)});
                //     print("IS GE: {}\n", .{self.flags.is(Flag.GE)});
                // }
            } else error.STACK_UNDERFLOW,
            .fwrite => return if (self.stack.len() > 2) {
                const stack_len = self.stack.len();
                const nan = self.stack.buf[stack_len - 2 - 1];

                return switch (nan.getType()) {
                    .U8, .I64, .U64 => {
                        const start = self.stack.buf[stack_len - 1 - 1].as(u64);
                        const end = self.stack.buf[stack_len - 0 - 1].as(u64);

                        if (start == end) {
                            return try switch (nan.as(u64)) {
                                1 => wstdin.writeAll(&[_]u8 {self.memory[start]}),
                                2 => wstdout.writeAll(&[_]u8 {self.memory[start]}),
                                3 => wstderr.writeAll(&[_]u8 {self.memory[start]}),
                                else => error.INVALID_FD,
                            };
                        }

                        try switch (nan.as(u64)) {
                            1 => wstdin.writeAll(self.memory[start..end]),
                            2 => wstdout.writeAll(self.memory[start..end]),
                            3 => wstderr.writeAll(self.memory[start..end]),
                            else => return error.INVALID_FD,
                        };
                        self.ip += 1;
                    },
                    .Str => {
                        const len = nan.as(u64);
                        const nans = self.stack.buf[stack_len - len - 1 - 2..stack_len - 1 - 2];
                        var str: [STR_CAP]u8 = undefined;
                        var i: usize = 0;
                        while (i < nans.len) : (i += 1)
                            str[i] = nans[i].as(u8);

                        const file_path = str[0..i];
                        const start = self.stack.buf[stack_len - 1 - 1].as(u64);
                        const end = self.stack.buf[stack_len - 0 - 1].as(u64);
                        if (start >= self.mp or end >= self.mp or start == end)
                            return error.ILLEGAL_MEMORY_ACCESS;

                        std.fs.cwd().writeFile(.{
                            .sub_path = file_path,
                            .data = self.memory[start..end],
                        }) catch |err| {
                            print("Failed to write to file {s}: {}\n", .{file_path, err});
                            exit(1);
                        };
                        self.ip += 1;
                    },
                    else => error.INVALID_TYPE,
                };
            } else error.STACK_UNDERFLOW,
            .fread => return if (self.stack.len() > 0) {
                const nan = self.stack.back().?;
                return switch (nan.getType()) {
                    .U8, .I64, .U64 => {
                        const buf = try switch (nan.as(u64)) {
                            1 => rstdin.readUntilDelimiter(self.memory[self.mp..MEMORY_CAP], '\n'),
                            2 => rstdout.readUntilDelimiter(self.memory[self.mp..MEMORY_CAP], '\n'),
                            3 => rstderr.readUntilDelimiter(self.memory[self.mp..MEMORY_CAP], '\n'),
                            else => return error.INVALID_FD,
                        };

                        if (buf.len >= READ_BUF_CAP or buf.len >= MEMORY_CAP)
                            return error.READ_BUF_OVERFLOW;

                        self.mp += buf.len;
                        self.ip += 1;
                    },
                    .Str => {
                        const len = nan.as(u64);
                        const stack_len = self.stack.len();
                        const nans = self.stack.buf[stack_len - len - 1..stack_len];
                        var str: [STR_CAP]u8 = undefined;
                        for (nans, 0..) |nan_, i|
                            str[i] = nan_.as(u8);

                        const n = std.fs.cwd().readFile(str[0..len], self.memory[self.mp..self.memory.len]) catch |err| {
                            print("ERROR: Failed to read file `{s}`: {}\n", .{str[0..len], err});
                            return error.FAILED_TO_READ_FILE;
                        };

                        if (n.len >= self.memory.len - self.mp)
                            return error.BUFFER_OVERFLOW;

                        self.mp += n.len;
                        self.ip += 1;
                    },
                    else => error.INVALID_TYPE,
                };
            } else error.STACK_UNDERFLOW,
            .eread => return if (self.stack.len() > 0) {
                const back = self.stack.back().?;
                const exact_idx = back.as(u64);

                if (exact_idx >= MEMORY_CAP)
                    return error.ILLEGAL_MEMORY_ACCESS;

                try self.stack.pushBack(NaNBox.from(u8, self.memory[exact_idx]));
                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .write => return if (self.stack.len() > 1) {
                const nan = self.stack.get(self.stack.len() - 1 - 1).?;
                const exact_idx = self.stack.back().?.as(u64);

                if (exact_idx >= MEMORY_CAP)
                    return error.ILLEGAL_MEMORY_ACCESS;

                self.ip += 1;
                return switch (nan.getType()) {
                    .U8 => self.memory[exact_idx] = nan.as(u8),
                    .I64, .U64 => self.memory[exact_idx] = @intCast(nan.as(u64)),
                    else => error.INVALID_TYPE,
                };
            } else error.STACK_UNDERFLOW,
            .read => return if (self.stack.len() > 1) {
                const last = self.stack.back().?;
                const prelast = self.stack.get(self.stack.len() - 2).?;

                var a = prelast.as(u64);
                const b = last.as(u64);

                if (b >= self.mp or b >= MEMORY_CAP)
                    return error.ILLEGAL_MEMORY_ACCESS;

                if (b - a + self.stack.len() >= STACK_CAP)
                    return error.STACK_OVERFLOW;

                prelast.* = NaNBox.from(u8, self.memory[a]);
                a += 1;
                last.* = NaNBox.from(u8, self.memory[a]);
                a += 1;
                for (self.memory[a..b]) |byte|
                    try self.stack.pushBack(NaNBox.from(u8, byte));

                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .pushsp => return if (self.stack.len() < STACK_CAP) {
                try self.stack.pushBack(NaNBox.from(u64, self.stack.len()));
                self.ip += 1;
            } else error.STACK_OVERFLOW,
            .pushmp => return if (self.stack.len() < STACK_CAP) {
                try self.stack.pushBack(NaNBox.from(u64, self.mp));
                self.ip += 1;
            } else error.STACK_OVERFLOW,
            .spush => return if (self.stack.len() < STACK_CAP) {
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
                            } else break :blk;
                            self.ip += 1;
                            return;
                        };

                        var nans: [STR_CAP]NaNBox = undefined;
                        for (str, 0..) |byte, i|
                            nans[i] = NaNBox.from(u8, byte);

                        try self.stack.appendSlice(nans[0..str.len]);
                        try self.stack.pushBack(NaNBox.from([]const u8, str));
                        self.ip += 1;
                    },
                    else => return error.INVALID_TYPE,
                };
            } else error.STACK_OVERFLOW,
            .spop => if (self.stack.len() > 0) {
                const n = self.stack.len();
                switch (self.stack.buf[n - 1].getType()) {
                    .Str => {
                        if (n < 1) return error.STACK_UNDERFLOW;
                        var str_len = self.stack.popBack().?.as(u64);
                        while (str_len > 0) : (str_len -= 1)
                            _ = self.stack.popBack();
                    },
                    else => _ = self.stack.popBack(),
                }
                self.ip += 1;
            } else return error.STACK_UNDERFLOW,
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
                var len = get_uint(inst).?;
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
            .nop => self.ip += 1,
            .label => self.ip += 1,
            .halt => self.halt = true,
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


// TODO:
//     Make heap do something.
//     Bake stdlib file into the executable.
