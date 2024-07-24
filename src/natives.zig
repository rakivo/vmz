const std = @import("std");
const Vm  = @import("vm.zig").Vm;

pub const Natives = struct {
    const REQUIRED_SIGNATURE = *const fn (*Vm) anyerror!void;

    map: std.StringHashMap(REQUIRED_SIGNATURE),

    const Self = @This();

    // const ARGS_CAP = 256;

    pub inline fn init(alloc: std.mem.Allocator) Self {
        return .{
            .map = std.StringHashMap(REQUIRED_SIGNATURE).init(alloc)
        };
    }

    pub inline fn deinit(self: *Self) void {
        self.map.deinit();
    }

    pub inline fn get(self: *Self, key: []const u8) ?REQUIRED_SIGNATURE {
        return self.map.get(key);
    }

    pub inline fn append(self: *Self, comptime name: []const u8, comptime ptr: REQUIRED_SIGNATURE) !void {
        try self.map.put(name, ptr);

        // const obj_type = @TypeOf(obj);

        // comptime var n = 0;
        // comptime var names: [ARGS_CAP][:0]const u8 = undefined;
        // comptime var ptrs: [ARGS_CAP]REQUIRED_SIGNATURE = undefined;

        // comptime {
        //     const fields = @typeInfo(obj_type).Struct.fields;
        //     if (fields.len > ARGS_CAP)
        //         @compileError("Amount of arguments is greater than the maximum capacity");

        //     for (fields) |f| {
        //         const info = @typeInfo(f.type);
        //         if (info != .Fn)
        //             @compileError("Expected argument to be a function");

        //         names[n] = f.name;
        //         ptrs[n] = @field(obj, f.name);
        //         n += 1;
        //     }
        // }

        // for (0..n) |i|
        //     try self.map.put(names[i], ptrs[i]);
    }
};
