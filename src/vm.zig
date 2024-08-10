const std       = @import("std");
const builtin   = @import("builtin");
const inst_mod  = @import("inst.zig");
const flag_mod  = @import("flags.zig");
const lexer_mod = @import("lexer.zig");
const Compiler  = @import("compiler.zig").Compiler;
const Heap      = @import("heap.zig").Heap;
const NaNBox    = @import("NaNBox.zig").NaNBox;
const Buffer    = @import("Buffer.zig").Buffer;
const Natives   = @import("natives.zig").Natives;
const Parsed    = @import("parser.zig").Parser.Parsed;

const Inst      = inst_mod.Inst;
const InstValue = inst_mod.InstValue;

const Loc       = lexer_mod.Token.Loc;

const Flag      = flag_mod.Flag;
const Flags     = flag_mod.Flags;

const print     = std.debug.print;
const exit      = std.process.exit;
const assert    = std.debug.assert;

const Writer    = std.fs.File.Writer;
const Reader    = std.fs.File.Reader;

pub const Buf      = []const NaNBox;
pub const BufMap   = std.StringHashMap(Buf);

pub const Program  = std.ArrayList(Inst);
pub const LabelMap = std.StringHashMap(u32);
pub const InstMap  = std.AutoHashMap(u32, Loc);

pub const DEBUG = false;

pub inline fn panic(comptime fmt: []const u8, args: anytype) !void {
    std.log.err(fmt, args);
    std.process.exit(1);
    unreachable;
}

pub const Vm = struct {
    ip: u64,
    mp: u64 = 0,
    hp: u64 = 128,
    halt: bool = false,
    program: []const Inst,
    alloc: std.mem.Allocator,

    buf_map: BufMap,

    stack: Buffer(NaNBox, STACK_CAP) = .{},
    call_stack: Buffer(u64, CALL_STACK_CAP) = .{},

    heap: Heap,
    natives: *const Natives,
    memory: [MEMORY_CAP]u8 = undefined,

    private: struct {
        flags: Flags = Flags.new(),

        im: InstMap,
        lm: LabelMap,

        rstdin:  Reader,
        wstdin:  Writer,
        rstdout: Reader,
        wstdout: Writer,
        rstderr: Reader,
        wstderr: Writer,
    },

    const Self = @This();

    pub const STR_CAP = 128;

    pub const MEMORY_CAP = 1024 * 8;

    pub const STACK_CAP = 1024;
    pub const INIT_STACK_CAP = STACK_CAP / 8;

    pub const CALL_STACK_CAP = 1024;
    pub const INIT_CALL_STACK_CAP = STACK_CAP / 8;

    pub const READ_BUF_CAP = 1024;

    pub fn init(parsed: Parsed, natives: *const Natives, alloc: std.mem.Allocator) !Self {
        var buf_map = BufMap.init(alloc);
        var ct_buf_map_iter = parsed.buf_map.iterator();
        while (ct_buf_map_iter.next()) |e| {
            const buf = switch (e.value_ptr.*.leftside) {
                .value => |v| blk: {
                    const mem = try alloc.alloc(NaNBox, e.value_ptr.size);
                    for (mem) |*ptr|
                        ptr.* = NaNBox.from(u8, v);

                    break :blk mem;
                },
                .type => |ty| blk: {
                    const mem = try alloc.alloc(NaNBox, e.value_ptr.size);

                    // Get Default value
                    const v = switch (ty) {
                        .I8  => .{.v = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), 0), .I8)},
                        .U8  => .{.v = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), 0), .U8)},
                        .I32 => .{.v = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), 0), .I32)},
                        .U32 => .{.v = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), 0), .U32)},
                        .F32 => .{.v = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), 0.0), .F32)},
                        .I64 => .{.v = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), 0), .I64)},
                        .U64 => .{.v = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), 0), .U64)},
                        .F64 => .{.v = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), 0.0), .F64)},
                        else => panic("UNIMPLEMENTED", .{})
                    };

                    for (mem) |*ptr| ptr.* = v;
                    break :blk mem;
                }
            };

            try buf_map.put(e.key_ptr.*, buf);
        }

        return .{
            .alloc = alloc,
            .ip = parsed.ip,
            .buf_map = buf_map,
            .natives = natives,
            .heap = try Heap.init(alloc),
            .program = parsed.program.items,
            .private = .{
                .lm = parsed.lm,
                .im = parsed.im,
                .rstdin  = std.io.getStdIn().reader(),
                .wstdin  = std.io.getStdIn().writer(),
                .rstdout = std.io.getStdOut().reader(),
                .wstdout = std.io.getStdOut().writer(),
                .rstderr = std.io.getStdErr().reader(),
                .wstderr = std.io.getStdErr().writer(),
            }
        };
    }

    inline fn get_ip(self: *Self, inst: *const Inst) !usize {
        return switch (inst.value) {
            .U64 => |ip| ip,
            .Str => |str| if (self.private.lm.get(str)) |ip| ip else return error.UNDEFINED_SYMBOL,
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
        self.ip = if (self.private.flags.is(flag))
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

    fn perform_mathop(self: *Self, comptime op: u8) void {
        if (self.stack.sz < 2)
            self.report_err(error.STACK_UNDERFLOW) catch exit(1);

        defer self.ip += 1;
        const a = self.stack.pop().?;
        const b = self.stack.back().?;
        b.* = switch (a.getType()) {
            .I64 => math_op(i64, a.as(i64), b.as(i64), op),
            .U64 => math_op(u64, a.as(u64), b.as(u64), op),
            .F64 => math_op(f64, a.as(f64), b.as(f64), op),
            else => self.report_err(error.INVALID_TYPE) catch exit(1)
        };
    }

    fn report_err(self: *const Self, err: anyerror) anyerror {
        const loc = self.private.im.get(@intCast(self.ip)).?;
        print("{s}:{d}:{d}: ERROR: {}\n", .{
            loc.file_path,
            loc.row + 1,
            loc.col + 1,
            err,
        });
        if (builtin.mode == .Debug) unreachable
        else exit(1);
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

    fn print_value(self: *Self, v: *const NaNBox, newline: bool) void {
        switch (v.getType()) {
            .Str => if (self.stack.sz > v.as(u64)) {
                const len = v.as(u64);
                const stack_len = self.stack.sz;
                const nans = self.stack.buf[stack_len - 1 - len..stack_len];

                if (nans.len > STR_CAP) panic("ERROR: STRING IS TOO LONG", .{});

                var str: [STR_CAP + 1]u8 = undefined;
                var i: usize = 0;
                while (i < nans.len) : (i += 1) {
                    str[i] = nans[i].as(u8);
                }

                if (newline) {
                    str[i - 1] = 10;
                    _ = self.private.wstdout.write(str[0..i]) catch |err| {
                        panic("Failed to write to stdout: {}", .{err});
                    };
                } else _ = self.private.wstdout.write(str[0..i - 1]) catch |err| {
                    panic("Failed to write to stdout: {}", .{err});
                };
            },
            else => {
                if (newline) _ = self.private.wstdout.print("{}\n", .{v}) catch |err| {
                    panic("Failed to write to stdout: {}", .{err});
                } else _ = self.private.wstdout.print("{}", .{v}) catch |err| {
                    panic("Failed to write to stdout: {}", .{err});
                };
            }
        }
    }

    inline fn write(self: *Self, fd: usize, bytes: []const u8) !void {
        return switch (fd) {
            1 => self.private.wstdin.writeAll(bytes),
            2 => self.private.wstdout.writeAll(bytes),
            3 => self.private.wstderr.writeAll(bytes),
            else => unreachable,
        };
    }

    fn execute_instruction(self: *Self, inst: *const Inst) !void {
        return switch (inst.type) {
            .push => return if (self.stack.sz < STACK_CAP) {
                defer self.ip += 1;
                return switch (inst.value) {
                    .U8  => |chr| self.stack.append(NaNBox.from(u8, chr)),
                    .NaN => |nan| self.stack.append(nan),
                    .F64 => |val| self.stack.append(NaNBox.from(f64, val)),
                    .U64 => |val| self.stack.append(NaNBox.from(u64, val)),
                    .I64 => |val| self.stack.append(NaNBox.from(i64, val)),
                    .Str => |str| {
                        var nans: [STR_CAP]NaNBox = undefined;
                        for (0..str.len) |i|
                            nans[i] = NaNBox.from(u8, str[i]);

                        self.stack.append_slice(nans[0..str.len]);
                        self.stack.append(NaNBox.from([]const u8, str));
                    },
                    .CtBuf => |buf| {
                        const slice = self.buf_map.get(buf.name).?;
                        self.stack.append(NaNBox.from(i64, @intCast(@intFromPtr(slice.ptr))));
                        self.stack.append(.{ .v = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), @intCast(slice.len)), .BufPtr) });
                    },
                    else => error.INVALID_TYPE,
                };
            } else error.STACK_OVERFLOW,
            .pop => return if (self.stack.sz > 0) {
                defer self.ip += 1;
                const n = self.stack.sz;
                switch (self.stack.buf[n - 1].getType()) {
                    .Str => {
                        if (n < 1) return error.STACK_UNDERFLOW;
                        const nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), self.stack.buf[n - 1].as(i64) - 1), .Str);
                        self.stack.buf[n - 2] = .{.v = nan};
                        self.stack.drop();
                    },
                    else => self.stack.drop()
                }
            } else error.STACK_UNDERFLOW,
            .swap => return if (get_uint(inst)) |uint| {
                const len = self.stack.sz;
                if (len > uint) {
                    const idx = len - uint - 1;
                    const t = self.stack.buf[len - 1];
                    self.stack.buf[len - 1] = self.stack.buf[idx];
                    self.stack.buf[idx] = t;
                    self.ip += 1;
                } else return error.STACK_UNDERFLOW;
            } else error.INVALID_TYPE,
            .dup => return switch (inst.value) {
                .U64 => |idx_| if (self.stack.sz > idx_) {
                    const idx = self.stack.sz - idx_ - 1;
                    const nth = self.stack.buf[idx];
                    self.stack.append(nth);
                    self.ip += 1;
                } else return error.STACK_UNDERFLOW,
                else => error.INVALID_TYPE
            },
            .inc => return if (self.stack.sz > 0) {
                const nan = self.stack.back().?;
                nan.* = switch (nan.getType()) {
                    .U8 => blk: {
                        const unan = nan.as(u8);
                        if (unan >= 1) break :blk NaNBox.from(u8, unan +% 1)
                        else           break :blk NaNBox.from(i8, @as(i8, @intCast(unan)) +% 1);
                    },
                    .U64 => blk: {
                        const unan = nan.as(u64);
                        if (unan >= 1) break :blk NaNBox.from(u64, unan +% 1)
                        else           break :blk NaNBox.from(i64, @as(i64, @intCast(unan)) +% 1);
                    },
                    .I64 => NaNBox.from(i64, nan.as(i64) +% 1),
                    .F64 => NaNBox.from(f64, nan.as(f64) + 1.0),
                    else => return error.INVALID_TYPE
                };
                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .dec => return if (self.stack.sz > 0) {
                const nan = self.stack.back().?;
                nan.* = switch (nan.getType()) {
                    .U8 => blk: {
                        const unan = nan.as(u8);
                        if (unan >= 1) break :blk NaNBox.from(u8, unan -% 1)
                        else           break :blk NaNBox.from(i8, @as(i8, @intCast(unan)) -% 1);
                    },
                    .U64 => blk: {
                        const unan = nan.as(u64);
                        if (unan >= 1) break :blk NaNBox.from(u64, unan -% 1)
                        else           break :blk NaNBox.from(i64, @as(i64, @intCast(unan)) -% 1);
                    },
                    .I64 => NaNBox.from(i64, nan.as(i64) -% 1),
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
            .je, .jne, .jnz, .jz, .jg, .jl, .jle, .jge => self.jmp_if_flag(inst),
            .jmp => self.ip = self.ip_check(try self.get_ip(inst)),
            .jmp_if => return if (self.stack.pop()) |b| {
                const boolean = switch (b.getType()) {
                    .BufPtr                                => true,
                    .InstValueType                         => false,
                    .Bool                                  => b.as(bool),
                    .I8, .U8, .I32, .U32, .I64, .U64, .Str => b.as(i64) > 0,
                    .F32, .F64                             => b.as(f64) > 0.0,
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
            .cmp => return if (self.stack.sz > 1) {
                const a = self.stack.buf[self.stack.sz - 2];
                const b = self.stack.pop().?;
                defer self.ip += 1;
                return switch (a.getType()) {
                    .I64 => self.private.flags.cmp(i64, a.as(i64), b.as(i64)),
                    .U64 => self.private.flags.cmp(u64, a.as(u64), b.as(u64)),
                    .F64 => self.private.flags.cmp(f64, a.as(f64), b.as(f64)),
                    else => error.INVALID_TYPE
                };
            } else error.STACK_UNDERFLOW,
            .not => return if (self.stack.sz > 0) {
                const b = self.stack.back().?;
                defer self.ip += 1;
                b.* = switch (b.getType()) {
                    .U8   => NaNBox.from(u8,   ~b.as(u8)),
                    .U64  => NaNBox.from(u64,  ~b.as(u64)),
                    .I64  => NaNBox.from(i64,  ~b.as(i64)),
                    .Bool => NaNBox.from(bool, !b.as(bool)),
                    .Str  => NaNBox.from(bool,  b.as(u64) > 0),
                    else  => return error.INVALID_TYPE
                };
            } else error.STACK_UNDERFLOW,
            .sizeof => return if (self.stack.sz > 0) {
                const nan = self.stack.back().?;
                const nan_type = nan.getType();
                const v = NaNBox.from(u64, switch (nan_type) {
                    .I8  => @sizeOf(i8),
                    .U8  => @sizeOf(u8),
                    .I64 => @sizeOf(i64),
                    .I32 => @sizeOf(i32),
                    .U64 => @sizeOf(u64),
                    .U32 => @sizeOf(u32),
                    .F64 => @sizeOf(f64),
                    .F32 => @sizeOf(f32),
                    .Str => nan.as(u64),
                    .Bool => @sizeOf(bool),
                    .BufPtr => nan.as(u64),
                    .InstValueType => @sizeOf(inst_mod.InstValueType),
                });

                if (nan_type == .BufPtr) self.stack.drop();
                if (nan_type == .Str)
                    for (0..nan.as(u64)) |_|
                        self.stack.drop();

                self.stack.back().?.* = v;
                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .fwrite => return if (self.stack.sz > 2) {
                const stack_len = self.stack.sz;
                const nan = self.stack.buf[stack_len - 2 - 1];

                const nan_type = nan.getType();
                if (2 + 2 < stack_len) blk: {
                    const offset = if (nan_type == .Str) nan.as(u64) else 0;
                    const potential_bufptr = self.stack.buf[stack_len - 2 - 2 - offset];
                    if (potential_bufptr.getType() != .BufPtr) break :blk;

                    const ptr_len = potential_bufptr.as(u64);

                    var bytes = try std.ArrayList(u8).initCapacity(self.alloc, ptr_len);
                    defer bytes.deinit();

                    const ptr: [*]NaNBox = @ptrFromInt(self.stack.buf[stack_len - 2 - 2 - 1 - offset].as(u64));
                    for (0..ptr_len) |i| try bytes.append(ptr[i].as(u8));
                    if (nan_type == .Str) {
                        const len = nan.as(u64);
                        const nans = self.stack.buf[stack_len - len - 1 - 2..stack_len - 1 - 2];
                        var str: [STR_CAP]u8 = undefined;
                        var i: usize = 0;
                        while (i < nans.len) : (i += 1)
                            str[i] = nans[i].as(u8);

                        const file_path = str[0..i];
                        const start = self.stack.buf[stack_len - 1 - 1].as(u64);
                        const end = self.stack.buf[stack_len - 0 - 1].as(u64);
                        if (start > ptr_len or end > ptr_len or start == end)
                            return error.ILLEGAL_MEMORY_ACCESS;

                        std.fs.cwd().writeFile(.{
                            .sub_path = file_path,
                            .data = bytes.items[start..end],
                        }) catch |err| panic("Failed to write to file {s}: {}\n", .{file_path, err});
                    } else {
                        const fd = nan.as(u64);
                        if (fd < 1 or fd > 3)
                            return error.INVALID_FD;

                        try switch (fd) {
                            1 => self.private.wstdin.print("{s}", .{bytes.items}),
                            2 => self.private.wstdout.print("{s}", .{bytes.items}),
                            3 => self.private.wstderr.print("{s}", .{bytes.items}),
                            else => unreachable,
                        };
                    }

                    self.ip += 1;
                    return;
                }

                return switch (nan_type) {
                    .U8, .I64, .U64 => {
                        const fd = nan.as(u64);
                        if (fd < 1 or fd > 3)
                            return error.INVALID_FD;

                        const start = self.stack.buf[stack_len - 1 - 1].as(u64);
                        const end = self.stack.buf[stack_len - 0 - 1].as(u64);

                        if (start >= MEMORY_CAP or end >= MEMORY_CAP)
                            return error.ILLEGAL_MEMORY_ACCESS;

                        const bytes = if (start == end) &[_]u8 {self.memory[start]}
                        else                                    self.memory[start..end];

                        try self.write(fd, bytes);
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
            .fread => return if (self.stack.sz > 2) {
                const stack_len = self.stack.sz;
                const nan = self.stack.buf[stack_len - 2 - 1];
                const nan_type = nan.getType();

                if (2 + 2 < stack_len) blk: {
                    const offset = if (nan_type == .Str) nan.as(u64) else 0;
                    const potential_bufptr = self.stack.buf[stack_len - 2 - 2 - offset];
                    if (potential_bufptr.getType() != .BufPtr) break :blk;

                    const ptr_len = potential_bufptr.as(u64);

                    const start = self.stack.buf[stack_len - 1 - 1].as(u64);
                    const end = self.stack.buf[stack_len - 0 - 1].as(u64);
                    if (start > ptr_len or end > ptr_len) return error.ILLEGAL_MEMORY_ACCESS;

                    const ptr: [*]NaNBox = @ptrFromInt(self.stack.buf[stack_len - 2 - 2 - 1 - offset].as(u64));
                    if (nan_type == .Str) {
                        const len = nan.as(u64);
                        const nans = self.stack.buf[stack_len - len - 1 - 2..stack_len - 1 - 2];
                        var str: [STR_CAP]u8 = undefined;
                        for (nans, 0..) |nan_, i| str[i] = nan_.as(u8);

                        var buf_: [8 * 1024]u8 = undefined;
                        const buf = std.fs.cwd().readFile(str[0..len], &buf_) catch |err| {
                            print("ERROR: Failed to read file `{s}`: {}\n", .{str[0..len], err});
                            return error.FAILED_TO_READ_FILE;
                        };

                        if (buf.len > ptr_len) return error.BUFFER_OVERFLOW;
                        for (0..buf.len) |i| ptr[i] = NaNBox.from(u8, buf[i]);
                    } else {
                        const fd = nan.as(u64);
                        var buf_: [8 * 1024]u8 = undefined;
                        const buf = try switch (fd) {
                            1 => self.private.rstdin .readUntilDelimiter(&buf_, '\n'),
                            2 => self.private.rstdout.readUntilDelimiter(&buf_, '\n'),
                            3 => self.private.rstderr.readUntilDelimiter(&buf_, '\n'),
                            else => self.report_err(error.INVALID_FD)
                        };

                        if (buf.len >= READ_BUF_CAP or buf.len > ptr_len)
                            return error.READ_BUF_OVERFLOW;

                        for (0..buf.len) |i| ptr[i] = NaNBox.from(u8, buf[i]);
                    }

                    self.ip += 1;
                    return;
                }

                return switch (nan_type) {
                    .U8, .I64, .U64 => {
                        const start = self.stack.buf[stack_len - 1 - 1].as(u64);
                        const end = self.stack.buf[stack_len - 0 - 1].as(u64);

                        if (start >= MEMORY_CAP or end >= MEMORY_CAP)
                            return error.ILLEGAL_MEMORY_ACCESS;

                        const buf = try switch (nan.as(u64)) {
                            1 => self.private.rstdin .readUntilDelimiter(self.memory[start..end], '\n'),
                            2 => self.private.rstdout.readUntilDelimiter(self.memory[start..end], '\n'),
                            3 => self.private.rstderr.readUntilDelimiter(self.memory[start..end], '\n'),
                            else => self.report_err(error.INVALID_FD)
                        };

                        if (buf.len >= READ_BUF_CAP or buf.len >= MEMORY_CAP)
                            return error.READ_BUF_OVERFLOW;

                        self.mp += buf.len;
                        self.ip += 1;
                    },
                    .Str => {
                        const len = nan.as(u64);
                        const nans = self.stack.buf[stack_len - len - 1 - 2..stack_len - 1 - 2];
                        var str: [STR_CAP]u8 = undefined;
                        for (nans, 0..) |nan_, i| str[i] = nan_.as(u8);

                        const start = self.stack.buf[stack_len - 1 - 1].as(u64);
                        const end = self.stack.buf[stack_len - 0 - 1].as(u64);

                        if (start >= MEMORY_CAP or end >= MEMORY_CAP)
                            return error.ILLEGAL_MEMORY_ACCESS;

                        const n = std.fs.cwd().readFile(str[0..len], self.memory[start..end]) catch |err| {
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
            .eread => return if (self.stack.sz > 0) {
                const back = self.stack.back().?;
                const exact_idx = back.as(u64);

                if (exact_idx >= MEMORY_CAP)
                    return error.ILLEGAL_MEMORY_ACCESS;

                self.stack.append(NaNBox.from(u8, self.memory[exact_idx]));
                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .write => return if (self.stack.sz > 2) {
                const v: u8 = @intCast(self.stack.buf[self.stack.sz - 1 - 1].as(u64));
                const a     = self.stack.buf[self.stack.sz - 1 - 2].as(u64);
                const b     = self.stack.buf[self.stack.sz - 1 - 3].as(u64);

                if (a >= MEMORY_CAP or b >= MEMORY_CAP)
                    return error.ILLEGAL_MEMORY_ACCESS;

                defer self.ip += 1;
                for (a..b) |i| self.memory[i] = v;
            } else error.STACK_UNDERFLOW,
            .read => return if (self.stack.sz > 1) {
                const last = self.stack.back().?;
                const prelast = self.stack.buf[self.stack.sz - 2];

                var a = prelast.as(u64);
                const b = last.as(u64);

                if (b > self.mp or b >= MEMORY_CAP)
                    return error.ILLEGAL_MEMORY_ACCESS;

                if (b - a + self.stack.sz >= STACK_CAP)
                    return error.STACK_OVERFLOW;

                self.stack.buf[self.stack.sz - 2] = NaNBox.from(u8, self.memory[a]);
                a += 1;
                last.* = NaNBox.from(u8, self.memory[a]);
                a += 1;
                for (self.memory[a..b]) |byte|
                    self.stack.append(NaNBox.from(u8, byte));

                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .pushsp => return if (self.stack.sz < STACK_CAP) {
                self.stack.append(NaNBox.from(u64, self.stack.sz));
                self.ip += 1;
            } else error.STACK_OVERFLOW,
            .pushmp => return if (self.stack.sz < STACK_CAP) {
                self.stack.append(NaNBox.from(u64, self.mp));
                self.ip += 1;
            } else error.STACK_OVERFLOW,
            .spush => return if (self.stack.sz < STACK_CAP) {
                return try switch (inst.value) {
                    .U8 => |chr| {
                        _ = blk: {
                            if (self.stack.back()) |back| {
                                if (back.getType() == .U8) {
                                    const str = &[_]u8 {back.as(u8), chr};
                                    self.stack.append(NaNBox.from(u8, chr));
                                    self.stack.append(NaNBox.from([]const u8, str));
                                    self.ip += 1;
                                    return;
                                } else if (back.getType() != .Str) break :blk;
                                const new_str_len = back.as(u64) + 1;
                                back.* = NaNBox.from(u8, chr);
                                const new_str_len_nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), @intCast(new_str_len)), .Str);
                                self.stack.append(NaNBox {.v = new_str_len_nan});
                            } else break :blk;
                        };
                        self.stack.append(NaNBox.from(u8, chr));
                    },
                    .NaN => |nan| self.stack.append(nan),
                    .F64 => |val| self.stack.append(NaNBox.from(f64, val)),
                    .U64 => |val| self.stack.append(NaNBox.from(u64, val)),
                    .I64 => |val| self.stack.append(NaNBox.from(i64, val)),
                    .Str => |str| { // TODO: clean this cood
                        _ = blk: {
                            if (self.stack.back()) |back| {
                                switch (back.getType()) {
                                    .Str => break :blk,
                                    .U8 => {
                                        const new_str_len = str.len + 1;
                                        for (str) |byte|
                                            self.stack.append(NaNBox.from(u8, byte));

                                        const new_str_len_nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), @intCast(new_str_len)), .Str);
                                        self.stack.append(NaNBox {.v = new_str_len_nan});
                                    },
                                    else => {
                                        const new_str_len = back.as(u64) + str.len;
                                        back.* = NaNBox.from(u8, str[0]);
                                        for (1..str.len) |i|
                                            self.stack.append(NaNBox.from(u8, str[i]));

                                        const new_str_len_nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), @intCast(new_str_len)), .Str);
                                        self.stack.append(NaNBox {.v = new_str_len_nan});
                                    }
                                }
                            } else break :blk;
                            self.ip += 1;
                            return;
                        };

                        var nans: [STR_CAP]NaNBox = undefined;
                        for (str, 0..) |byte, i|
                            nans[i] = NaNBox.from(u8, byte);

                        if (self.stack.back()) |back| {
                            if (back.getType() == .Str) {
                                const new_str_len = str.len + back.as(u64);
                                const new_str_len_nan = NaNBox.setType(NaNBox.setValue(NaNBox.mkInf(), @intCast(new_str_len)), .Str);

                                back.* = nans[0];
                                self.stack.append_slice(nans[1..str.len]);
                                self.stack.append(NaNBox {.v = new_str_len_nan});
                            }
                        } else {
                            self.stack.append_slice(nans[0..str.len]);
                            self.stack.append(NaNBox.from([]const u8, str));
                        }

                        self.ip += 1;
                    },
                    else => error.INVALID_TYPE,
                };
            } else error.STACK_OVERFLOW,
            .spop => return if (self.stack.sz > 0) {
                const n = self.stack.sz;
                switch (self.stack.buf[n - 1].getType()) {
                    .Str => {
                        if (n < 1) return error.STACK_UNDERFLOW;
                        var str_len = self.stack.pop().?.as(u64);
                        while (str_len > 0) : (str_len -= 1)
                            self.stack.drop();
                    },
                    else => self.stack.drop(),
                }
                self.ip += 1;
            } else error.STACK_UNDERFLOW,
            .call => return if (self.call_stack.sz + 1 < CALL_STACK_CAP) {
                const ip = self.ip_check(try self.get_ip(inst));
                if (ip + 1 > self.program.len)
                    return error.ILLEGAL_INSTRUCTION_ACCESS;

                self.call_stack.append(self.ip + 1);
                self.ip = ip;
            } else error.CALL_STACK_OVERFLOW,
            .ret => return if (self.call_stack.sz > 0) {
                self.ip = self.call_stack.pop().?;
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
                    if (ptr.ac > self.stack.sz)
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
        while (!self.halt and self.ip < self.program.len) {
            const inst = self.program[self.ip];
            self.execute_instruction(&inst)
                catch |err| return self.report_err(err);
            if (DEBUG) print("INST: {}\nSTACK: {any}\n", .{inst, self.stack.buf[0..self.stack.sz]});
        }
    }

    pub fn compile_program_to_x86_64(self: *Self, file_path: []const u8) !void {
        var compiler = try Compiler.new(self.alloc, self.program, file_path);
        try compiler.compile2nasm();
    }
};


// TODO:
//     Make heap do something.
//     Bake stdlib file into the executable.
