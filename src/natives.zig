const std = @import("std");
const vm  = @import("vm.zig");

const Vm = vm.Vm;
const panic = vm.panic;

const print = std.debug.print;

pub const Natives = struct {
    const REQUIRED_SIGNATURE = fn (*Vm) anyerror!void;

    map: std.StringHashMap(*const REQUIRED_SIGNATURE),

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, comptime obj: anytype) Self {
        var map = std.StringHashMap(*const REQUIRED_SIGNATURE).init(alloc);

        const info = @typeInfo(@TypeOf(obj));
        inline for (info.Struct.fields) |field| {
            const field_value = @field(obj, field.name);
            const signature = @TypeOf(field_value);

            if (signature != REQUIRED_SIGNATURE)
                @compileError("Signature: " ++ signature ++ " does not match required signature: " ++ REQUIRED_SIGNATURE ++ "\n");

            map.put(field.name, field_value);
        }

        return .{.map = map};
    }

    pub inline fn deinit(self: *Self) void {
        self.map.deinit();
    }
};
