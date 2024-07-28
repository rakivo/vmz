const std    = @import("std");
const NaNBox = @import("NaNBox.zig").NaNBox;

const exit  = std.process.exit;
const print = std.debug.print;

pub const Heap = struct {
    cap: usize,
    buf: []u8,
    alloc: std.mem.Allocator,

    pub const CAP = 1024 * 1024;
    pub const INIT_CAP = 128;

    const Self = @This();

    pub inline fn init(alloc: std.mem.Allocator) !Self {
        return .{
            .buf = try alloc.alloc(u8, INIT_CAP),
            .cap = INIT_CAP,
            .alloc = alloc,
        };
    }

    pub inline fn deinit(self: *Self) void {
        self.alloc.free(self.buf);
    }

    pub fn grow(self: *Self) !void {
        if (self.cap < CAP) {
            self.buf = try self.alloc.realloc(self.buf, self.cap * 2);
            self.cap *= 2;
        } else return error.FAILED_TO_GROW;
    }

    pub fn shrink(self: *Self) !void {
        if (self.alloc.resize(self.buf, self.cap / 2))
            return error.FAILED_TO_RESIZE;

        self.cap /= 2;
    }
};
