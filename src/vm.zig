const std       = @import("std");
const builtin   = @import("builtin");
const inst_mod  = @import("inst.zig");
const flag_mod  = @import("flags.zig");
const lexer_mod = @import("lexer.zig");
const Heap      = @import("heap.zig").Heap;
const NaNBox    = @import("NaNBox.zig").NaNBox;
const Natives   = @import("natives.zig").Natives;
const VecDeque  = @import("VecDeque.zig").VecDeque;
const Parsed    = @import("parser.zig").Parser.Parsed;

const Inst      = inst_mod.Inst;
const InstValue = inst_mod.InstValue;

const Loc       = lexer_mod.Token.Loc;

const Flag      = flag_mod.Flag;
const Flags     = flag_mod.Flags;

const print     = std.debug.print;
const exit      = std.process.exit;
const assert    = std.debug.assert;

const rstdin    = std.io.getStdOut().reader();
const wstdin    = std.io.getStdOut().writer();

const rstdout   = std.io.getStdOut().reader();
const wstdout   = std.io.getStdOut().writer();

const rstderr   = std.io.getStdOut().reader();
const wstderr   = std.io.getStdOut().writer();

pub const Program  = std.ArrayList(Inst);
pub const LabelMap = std.StringHashMap(u32);
pub const InstMap  = std.AutoHashMap(u32, Loc);

const DEBUG = false;

pub inline fn panic(comptime fmt: []const u8, args: anytype) !void {
    std.log.err(fmt, args);
    std.process.exit(1);
    unreachable;
}

pub const Vm = struct {
    mp: u64 = 0,
    hp: u64 = 128,
    halt: bool = false,
    flags: Flags = Flags.new(),

    ip: u64,
    lm: LabelMap,
    im: InstMap,
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

    pub fn init(parsed: Parsed, natives: *const Natives, alloc: std.mem.Allocator) !Self {
        return .{
            .alloc = alloc,
            .ip = parsed.ip,
            .lm = parsed.lm,
            .im = parsed.im,
            .natives = natives,
            .heap = try Heap.init(alloc),
            .program = parsed.program.items,
            .stack = try VecDeque(NaNBox).initCapacity(alloc, INIT_STACK_CAP),
            .call_stack = try VecDeque(u64).initCapacity(alloc, INIT_CALL_STACK_CAP),
        };
    }

    pub fn deinit(self: *Self) void {
        self.heap.deinit();
        self.stack.deinit();
        self.call_stack.deinit();
        self.alloc.free(self.program);
    }

    inline fn get_ip(self: *Self, inst: *const Inst) !usize {
        return switch (inst.value) {
            .U64 => |ip| ip,
            .Str => |str| if (self.lm.get(str)) |ip| ip else return error.UNDEFINED_SYMBOL,
            .NaN => |nan| @intCast(nan.as(i64)),
            else => error.INVALID_TYPE
        };
    }

    inline fn ip_check(self: *Self, ip: usize) usize {
        if (ip < 0 or ip > self.program.len)
            self.report_err(error.ILLEGAL_INSTRUCTION_ACCESS) catch exit(1);

        return ip;
    }

    inline fn jmp_if_flag(self: *Self, inst: *const Inst) !void {
        const flag = Flag.from_inst(inst).?;
        self.ip = if (self.flags.is(flag))
            self.ip_check(try self.get_ip(inst))
        else
            self.ip + 1;
    }

    inline fn math_op(comptime T: type, a: T, b: T, comptime op: u8) NaNBox {
        return NaNBox.from(T, switch (op) {
            '+' => b + a,
            '-' => b - a,
            '/' => if (T == i64) @divFloor(b, a) else b / a,
            '*' => b * a,
            else => @compileError(std.fmt.comptimePrint("UNEXPECTED OP: {c}", .{op})),
        });
    }

    inline fn perform_mathop(self: *Self, comptime op: u8) void {
        if (self.stack.len() < 2)
            self.report_err(error.STACK_UNDERFLOW) catch exit(1);

        defer self.ip += 1;
        const a = self.stack.popBack().?;
        const b = self.stack.back().?;
        b.* = switch (a.getType()) {
            .I64 => math_op(i64, a.as(i64), b.as(i64), op),
            .U64 => math_op(u64, a.as(u64), b.as(u64), op),
            .F64 => math_op(f64, a.as(f64), b.as(f64), op),
            else => self.report_err(error.INVALID_TYPE) catch exit(1)
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
            unreachable;
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
            else => null
        };
    }

    inline fn get_uint(inst: *const Inst) ?u64 {
        return if (get_int(inst)) |some| @intCast(some) else null;
    }

    // // This function will work properly ONLY if bytes of the string is the last element on the stack.
    // // For example here it will work: `[..., 114, 97, 107, 105, 118, 111, Str size: 6]`,
    // // And here it won't: `[114, 97, 107, 105, 118, 111, Str size: 6, ...]`,
    // pub fn get_str(self: *Self, str_len: usize, is_length_on_stack: bool) []const u8 {
    //     const stack_len = self.stack.len();
    //     var str: [STR_CAP + 1]u8 = undefined;
    //     var start: usize = undefined;
    //     var end: usize = undefined;
    //     if (is_length_on_stack) {
    //         end = stack_len - 1;
    //         start = stack_len - 1 - str_len;
    //     } else {
    //         start = stack_len - str_len;
    //         end = stack_len;
    //     }

    //     const nans = self.stack.buf[start..end];
    //     for (0..nans.len) |i|
    //         str[i] = nans[i].as(u8);

    //     return str[0..end - 2];
    // }

    fn print_value(self: *Self, v: *const NaNBox, newline: bool) void {
        switch (v.getType()) {
            .Bool => {
                const b: u8 = if (v.as(bool)) 1 else 0;
                const buf = if (newline) &[_]u8 {b, 10} else &[_]u8 {b};
                _ = wstdout.write(buf) catch |err| {
                    panic("Failed to write to stdout: {}", .{err});
                };
            },
            .U8 => {
                const buf = if (newline) &[_]u8 {v.as(u8), 10} else &[_]u8 {v.as(u8)};
                _ = wstdout.write(buf) catch |err| {
                    panic("Failed to write to stdout: {}", .{err});
                };
            },
            .I64, .U64, .F64 => {
                var buf: [32]u8 = undefined;
                const ret = if (newline) std.fmt.bufPrint(&buf,  "{}\n", .{v}) catch |err| {
                    panic("Failed to buf print value: {}: {}", .{v, err});
                } else std.fmt.bufPrint(&buf,  "{}", .{v}) catch |err| {
                    panic("Failed to buf print value: {}: {}", .{v, err});
                };

                _ = wstdout.write(ret) catch |err| {
                    panic("Failed to write to stdout: {}", .{err});
                };
            },
            .Str => if (self.stack.len() > v.as(u64)) {
                const len = v.as(u64);
                const stack_len = self.stack.len();
                const nans = self.stack.buf[stack_len - 1 - len..];
                var str: [STR_CAP + 1]u8 = undefined;
                var i: usize = 0;
                while (i < nans.len) : (i += 1)
                    str[i] = nans[i].as(u8);

                if (newline) {
                    str[i - 1] = 10;
                    _ = wstdout.write(str[0..i]) catch |err| {
                        panic("Failed to write to stdout: {}", .{err});
                    };
                } else _ = wstdout.write(str[0..i - 1]) catch |err| {
                    panic("Failed to write to stdout: {}", .{err});
                };
            }
            else self.report_err(error.INVALID_TYPE) catch exit(1)
        }
    }

    fn execute_instruction(self: *Self, inst: *const Inst) !void {
        return switch (inst.type) {
            .push => return if (self.stack.len() < STACK_CAP) {
                defer self.ip += 1;
                switch (inst.value) {
                    .U8  => |chr| self.stack.pushBack(NaNBox.from(u8, chr)),
                    .NaN => |nan| self.stack.pushBack(nan),
                    .F64 => |val| self.stack.pushBack(NaNBox.from(f64, val)),
                    .U64 => |val| self.stack.pushBack(NaNBox.from(u64, val)),
                    .I64 => |val| self.stack.pushBack(NaNBox.from(i64, val)),
                    .Str => |str| {
                        var nans: [STR_CAP]NaNBox = undefined;
                        for (0..str.len) |i|
                            nans[i] = NaNBox.from(u8, str[i]);

                        self.stack.appendSlice(nans[0..str.len]);
                        self.stack.pushBack(NaNBox.from([]const u8, str));
                    },
                    else => return error.INVALID_TYPE,
                }
            } else error.STACK_OVERFLOW,
            .pop => return if (self.stack.len() > 0) {
                defer self.ip += 1;
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
                    self.stack.pushBack(nth);
                    self.ip += 1;
                } else return error.STACK_UNDERFLOW,
                else => error.INVALID_TYPE
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
            .iadd => self.perform_mathop('+'),
            .isub => self.perform_mathop('-'),
            .idiv => self.perform_mathop('/'),
            .imul => self.perform_mathop('*'),
            .fadd => self.perform_mathop('+'),
            .fsub => self.perform_mathop('-'),
            .fdiv => self.perform_mathop('/'),
            .fmul => self.perform_mathop('*'),
            .je, .jne, .jg, .jl, .jle, .jge => self.jmp_if_flag(inst),
            .jmp => self.ip = self.ip_check(try self.get_ip(inst)),
            .jmp_if => return if (self.stack.popBack()) |b| {
                const boolean = switch (b.getType()) {
                    .Bool => b.as(bool),
                    .F64 => b.as(f64) > 0.0,
                    .U8, .I64, .U64, .Str => b.as(u64) > 0,
                };

                self.ip = if (boolean)
                    self.ip_check(try self.get_ip(inst))
                else
                    self.ip + 1;
            } else error.STACK_UNDERFLOW,
            .dmpln => return if (self.stack.back()) |v| {
                self.print_value(v, true);
                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .dmp => return if (self.stack.back()) |v| {
                self.print_value(v, false);
                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .cmp => return if (self.stack.len() > 1) {
                const a = self.stack.buf[self.stack.len() - 2];
                const b = self.stack.popBack().?;
                defer self.ip += 1;
                return switch (a.getType()) {
                    .I64 => self.flags.cmp(i64, a.as(i64), b.as(i64)),
                    .U64 => self.flags.cmp(u64, a.as(u64), b.as(u64)),
                    .F64 => self.flags.cmp(f64, a.as(f64), b.as(f64)),
                    else => error.INVALID_TYPE
                };
            } else error.STACK_UNDERFLOW,
            .not => return if (self.stack.len() > 0) {
                const b = self.stack.back().?;
                defer self.ip += 1;
                b.* = switch (b.getType()) {
                    .U8 => NaNBox.from(u8, ~b.as(u8)),
                    .U64 => NaNBox.from(u64, ~b.as(u64)),
                    .I64 => NaNBox.from(i64, ~b.as(i64)),
                    .Bool => NaNBox.from(bool, !b.as(bool)),
                    .Str => NaNBox.from(bool, b.as(u64) > 0),
                    else => return error.INVALID_TYPE
                };
            } else error.STACK_UNDERFLOW,
            .fwrite => return if (self.stack.len() > 2) {
                const stack_len = self.stack.len();
                const nan = self.stack.buf[stack_len - 2 - 1];

                return switch (nan.getType()) {
                    .U8, .I64, .U64 => {
                        const start = self.stack.buf[stack_len - 1 - 1].as(u64);
                        const end = self.stack.buf[stack_len - 0 - 1].as(u64);

                        if (start == end) {
                            try switch (nan.as(u64)) {
                                1 => wstdin.writeAll(&[_]u8 {self.memory[start]}),
                                2 => wstdout.writeAll(&[_]u8 {self.memory[start]}),
                                3 => wstderr.writeAll(&[_]u8 {self.memory[start]}),
                                else => error.INVALID_FD
                            };
                        } else {
                            try switch (nan.as(u64)) {
                                1 => wstdin.writeAll(self.memory[start..end]),
                                2 => wstdout.writeAll(self.memory[start..end]),
                                3 => wstderr.writeAll(self.memory[start..end]),
                                else => error.INVALID_FD
                            };
                        }

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
                        if (start >= MEMORY_CAP or end >= MEMORY_CAP or start == end)
                            return error.ILLEGAL_MEMORY_ACCESS;

                        std.fs.cwd().writeFile(.{
                            .sub_path = file_path,
                            .data = self.memory[start..end],
                        }) catch |err|
                            panic("Failed to write to file {s}: {}\n", .{file_path, err});

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
                            1 => rstdin.readUntilDelimiter(self.memory[self.mp..], '\n'),
                            2 => rstdout.readUntilDelimiter(self.memory[self.mp..], '\n'),
                            3 => rstderr.readUntilDelimiter(self.memory[self.mp..], '\n'),
                            else => self.report_err(error.INVALID_FD)
                        };

                        if (buf.len >= READ_BUF_CAP or buf.len >= MEMORY_CAP)
                            return error.READ_BUF_OVERFLOW;

                        self.mp += buf.len;
                        self.ip += 1;
                    },
                    .Str => {
                        const len = nan.as(u64);
                        const stack_len = self.stack.len();
                        const nans = self.stack.buf[stack_len - len - 1..stack_len - 1];
                        var str: [STR_CAP]u8 = undefined;
                        for (nans, 0..) |nan_, i|
                            str[i] = nan_.as(u8);

                        const n = std.fs.cwd().readFile(str[0..len], self.memory[self.mp..]) catch |err| {
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

                defer self.ip += 1;
                self.stack.pushBack(NaNBox.from(u8, self.memory[exact_idx]));
            } else error.STACK_UNDERFLOW,
            .write => return if (self.stack.len() > 1) {
                const nan = self.stack.get(self.stack.len() - 1 - 1).?;
                const exact_idx = self.stack.back().?.as(u64);

                if (exact_idx >= MEMORY_CAP)
                    return error.ILLEGAL_MEMORY_ACCESS;

                defer self.ip += 1;
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

                if (b > self.mp or b >= MEMORY_CAP)
                    return error.ILLEGAL_MEMORY_ACCESS;

                if (b - a + self.stack.len() >= STACK_CAP)
                    return error.STACK_OVERFLOW;

                prelast.* = NaNBox.from(u8, self.memory[a]);
                a += 1;
                last.* = NaNBox.from(u8, self.memory[a]);
                a += 1;
                for (self.memory[a..b]) |byte|
                    self.stack.pushBack(NaNBox.from(u8, byte));

                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .pushsp => return if (self.stack.len() < STACK_CAP) {
                self.stack.pushBack(NaNBox.from(u64, self.stack.len()));
                self.ip += 1;
            } else error.STACK_OVERFLOW,
            .pushmp => return if (self.stack.len() < STACK_CAP) {
                self.stack.pushBack(NaNBox.from(u64, self.mp));
                self.ip += 1;
            } else error.STACK_OVERFLOW,
            .spush => return if (self.stack.len() < STACK_CAP) {
                return try switch (inst.value) {
                    .U8 => |chr| {
                        _ = blk: {
                            if (self.stack.back()) |back| {
                                if (back.getType() == .U8) {
                                    const str = &[_]u8 {back.as(u8), chr};
                                    self.stack.pushBack(NaNBox.from(u8, chr));
                                    self.stack.pushBack(NaNBox.from([]const u8, str));
                                    self.ip += 1;
                                    return;
                                } else if (back.getType() != .Str) break :blk;
                                const new_str_len = back.as(u64) + 1;
                                back.* = NaNBox.from(u8, chr);
                                const new_str_len_nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), @intCast(new_str_len)), .Str);
                                self.stack.pushBack(NaNBox {.v = new_str_len_nan});
                            } else break :blk;
                        };
                        self.stack.pushBack(NaNBox.from(u8, chr));
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
                                    self.stack.pushBack(NaNBox.from(u8, str[i]));

                                const new_str_len_nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), @intCast(new_str_len)), .Str);
                                self.stack.pushBack(NaNBox {.v = new_str_len_nan});
                            } else break :blk;
                            self.ip += 1;
                            return;
                        };

                        var nans: [STR_CAP]NaNBox = undefined;
                        for (str, 0..) |byte, i|
                            nans[i] = NaNBox.from(u8, byte);

                        self.stack.appendSlice(nans[0..str.len]);
                        self.stack.pushBack(NaNBox.from([]const u8, str));
                        self.ip += 1;
                    },
                    else => error.INVALID_TYPE,
                };
            } else error.STACK_OVERFLOW,
            .spop => return if (self.stack.len() > 0) {
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
            } else error.STACK_UNDERFLOW,
            .call => return if (self.call_stack.len() + 1 < CALL_STACK_CAP) {
                const ip = self.ip_check(try self.get_ip(inst));
                if (ip + 1 > self.program.len)
                    return error.ILLEGAL_INSTRUCTION_ACCESS;

                self.call_stack.pushBack(self.ip + 1);
                self.ip = ip;
            } else error.CALL_STACK_OVERFLOW,
            .ret => return if (self.call_stack.len() > 0) {
                self.ip = self.call_stack.popBack().?;
            } else error.CALL_STACK_UNDERFLOW,
            .alloc => return if (self.hp < Heap.CAP) {
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
            } else error.FAILED_TO_GROW,
            .native => {
                const name = switch (inst.value) {
                    .Str => |str| str,
                    else => return error.INVALID_TYPE,
                };
                const ptro = self.natives.map.get(name);
                if (ptro) |ptr| {
                    if (ptr.ac > self.stack.len())
                        return error.STACK_UNDERFLOW;

                    try ptr.f(self);
                } else {
                    print("Undefined native function: {s}\n", .{name});
                    if (self.natives.map.count() > 0) {
                        var it = self.natives.map.keyIterator();
                        print("Names of natives provided: {s}", .{it.next().?.*});
                        while (it.next()) |key|
                            print(", {s}", .{key.*});

                        print("\n", .{});
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
        while (!self.halt and self.ip < self.program.len)
            self.execute_instruction(&self.program[self.ip])
            catch |err| return self.report_err(err);
    }
};


// TODO:
//     Make heap do something.
//     Bake stdlib file into the executable.
