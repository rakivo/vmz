const std = @import("std");
const vm  = @import("vm.zig");

const Vm    = vm.Vm;
const panic = vm.panic;
const print = std.debug.print;

pub const Natives = struct {
    const REQUIRED_SIGNATURE = fn (*Vm) anyerror!void;

    map: std.StringHashMap(*const REQUIRED_SIGNATURE),

    const Self = @This();

    /// To properly use this function, as we do not have macros in Zig, and AFAIK there is NO way get the proper name of the field from object if you don't provide it explicitly. By `proper name of the field` I mean, for example:
    /// ```
    /// fn push_420(vm: *Vm) !void {
    ///     const nan = NaNBox.from(u64, 420);
    ///     vm.stack.pushBack(nan);
    /// }
    ///
    /// fn push_69(vm: *Vm) !void {
    ///     const nan = NaNBox.from(u64, 69);
    ///     vm.stack.pushBack(nan);
    /// }
    ///
    /// pub fn main() !void {
    ///     ...
    ///     var natives = Natives.init(arena.allocator(), .{
    ///         push_420,
    ///         push_69
    ///     });
    ///     ...
    /// }
    /// ```
    /// Here, proper names are `push_420` and `push_69`, basically the names of the functions.
    /// But in Zig, if you do not provide the name explicitly, as I already said, field is considered nameless,
    /// and the name replaced with it zero-based index, counting from first field. And because of that,
    /// we are getting `0` and `1`, and not `push_420` and `push_69`.
    ///
    /// So, if you want functions to have proper name in the natives map, unfortunately, you've got to specify them EXPLICITLY:
    /// ```
    /// var natives = Natives.init(arena.allocator(), .{
    ///     .push_420 = push_420,
    ///     .push_69 = push_69
    /// });
    /// ```
    /// Or, you can specify your custom names.
    pub fn init(alloc: std.mem.Allocator, comptime obj: anytype) !Self {
        var map = std.StringHashMap(*const REQUIRED_SIGNATURE).init(alloc);

        const info = @typeInfo(@TypeOf(obj));
        comptime if (info != .Struct) {
            @compileError("Expected provided object to be struct");
        };

        inline for (info.Struct.fields) |field| {
            const field_value = @field(obj, field.name);
            const signature = @TypeOf(field_value);

            comptime if (std.ascii.isDigit(field.name[0])) {
                @compileError("Please, specify name of your fields specifically, if you want them to have proper names in the natives map, for example:\n" ++
                              "var natives = Natives.init(arena.allocator(), .{\n" ++
                              "    .push_420 = push_420,\n" ++
                              "    .push_69 = push_69\n" ++
                              "});");
            };

            comptime if (signature != REQUIRED_SIGNATURE)
                @compileError("Signature of provided function: `" ++ @typeName(signature) ++ "`\nDoes not match required signature: `" ++ @typeName(REQUIRED_SIGNATURE) ++ "`");

            try map.put(field.name, field_value);
        }

        return .{.map = map};
    }

    pub inline fn deinit(self: *Self) void {
        self.map.deinit();
    }
};
