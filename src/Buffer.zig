pub fn Buffer(comptime T: type, comptime S: usize) type {
    return struct {
        buf: [S]T = undefined,
        sz: usize = 0,

        const Self = @This();

        pub inline fn new() Self {
            return .{};
        }

        pub inline fn append(self: *Self, v: T) void {
            self.buf[self.sz] = v;
            self.sz += 1;
        }

        pub inline fn pop(self: *Self) ?T {
            return if (self.sz > 0) {
                self.sz -= 1;
                const ret = self.buf[self.sz];
                self.buf[self.sz] = undefined;
                return ret;
            } else null;
        }

        pub inline fn drop(self: *Self) void {
            if (self.sz > 0) self.sz -= 1;
        }

        pub inline fn back(self: *Self) ?*T {
            return if (self.sz > 0) {
                return &self.buf[self.sz - 1];
            } else null;
        }

        pub inline fn append_slice(self: *Self, slice: []const T) void {
            for (slice) |nan| {
                self.buf[self.sz] = nan;
                self.sz += 1;
            }
        }
    };
}
