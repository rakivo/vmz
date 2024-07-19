const Inst = @import("inst.zig").Inst;

pub const Flag = enum {
    E, G, L, NE, GE, LE,

    const Self = @This();

    pub inline fn from_inst(inst: *const Inst) ?Self {
        return switch(inst.type) {
            .je  => .E,
            .jg  => .G,
            .jl  => .L,
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

    pub fn new() Self {
        comptime return .{};
    }

    pub fn cmp(self: *Self, a: i64, b: i64) void {
        self._buf = 0;
        if (a == b) {
            self.set(Flag.E);
            self.set(Flag.GE);
            self.set(Flag.LE);
        } else {
            self.set(Flag.NE);
            if (a > b) {
                self.set(Flag.G);
            } else if (a < b) {
                self.set(Flag.L);
            }
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
