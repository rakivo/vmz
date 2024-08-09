const print = @import("std").debug.print;
const DEBUG = @import("vm.zig").DEBUG;
const Inst  = @import("inst.zig").Inst;

pub const Flag = enum {
    E, G, L, Z, NZ, NE, GE, LE,

    const Self = @This();

    pub inline fn from_inst(inst: *const Inst) ?Self {
        return switch(inst.type) {
            .je  => .E,
            .jg  => .G,
            .jl  => .L,
            .jz  => .Z,
            .jnz => .NZ,
            .jne => .NE,
            .jge => .GE,
            .jle => .LE,
            else => null
        };
    }
};

pub const Flags = packed struct {
    _buf: u8 = 0,

    const Self = @This();

    const ONE: u8 = 1;

    pub inline fn new() Self {
        comptime return .{};
    }

    pub fn cmp(self: *Self, comptime T: type, a: T, b: T) void {
        self._buf = 0;
        if (a == b) {
            self.set(.Z);
            self.set(.E);
            self.set(.GE);
            self.set(.LE);
        } else {
            self.set(.NZ);
            self.set(.NE);
            if (a > b) {
                self.set(.G);
                self.set(.GE);
            } else if (a < b) {
                self.set(.L);
                self.set(.LE);
            }
        }

        if (DEBUG) {
            print("FLAGS:\n", .{});
            print("    is E:  {}\n", .{self.is(.E)});
            print("    is G:  {}\n", .{self.is(.G)});
            print("    is L:  {}\n", .{self.is(.L)});
            print("    is Z:  {}\n", .{self.is(.Z)});
            print("    is NZ: {}\n", .{self.is(.NZ)});
            print("    is NE: {}\n", .{self.is(.NE)});
            print("    is GE: {}\n", .{self.is(.GE)});
            print("    is LE: {}\n", .{self.is(.LE)});
        }
    }

    pub inline fn set(self: *Self, flag: Flag) void {
        self._buf |= ONE << @as(u8, @intFromEnum(flag));
    }

    pub inline fn reset(self: *Self, flag: Flag) void {
        self._buf &= ~(ONE << @as(u8, @intFromEnum(flag)));
    }

    pub inline fn is(self: *const Self, flag: Flag) bool {
        const u8_flag = @intFromEnum(flag);
        return (self._buf & (ONE << u8_flag)) >> u8_flag != 0;
    }
};
