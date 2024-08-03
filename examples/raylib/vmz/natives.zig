const std = @import("std");
const vm  = @import("vm.zig");

const Vm    = vm.Vm;
const panic = vm.panic;
const print = std.debug.print;

const REQUIRED_SIGNATURE = fn (*Vm) anyerror!void;

pub const FnPtr = struct {
    f: *const REQUIRED_SIGNATURE,
    ac: usize,
};

pub const Natives = struct {
    map: std.StringHashMap(FnPtr),

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
        var map = std.StringHashMap(FnPtr).init(alloc);

        const info = @typeInfo(@TypeOf(obj));
        comptime if (info != .Struct)
            @compileError("Expected provided object to be struct");

        inline for (info.Struct.fields) |field| {
            const field_value = @field(obj, field.name);

            const ninfo = @typeInfo(@TypeOf(field_value));
            const nfields = ninfo.Struct.fields;

            comptime if (ninfo != .Struct)
                @compileError("Expected provided object to be struct");

            comptime if (nfields.len != 2)
                @compileError("Expected provided object to be in following format: .{ fn_ptr, args_count }");

            const ptr = @field(field_value, "0");
            const ac = @field(field_value, "1");

            comptime {
                const signature = @TypeOf(ptr);

                if (std.ascii.isDigit(field.name[0])) {
                    @compileError("Please, specify name of your fields specifically, if you want them to have proper names in the natives map, for example:\n" ++
                                      "var natives = Natives.init(arena.allocator(), .{\n" ++
                                      "    .push_420 = push_420,\n" ++
                                      "    .push_69 = push_69\n" ++
                                      "});");
                }

                if (signature != REQUIRED_SIGNATURE)
                    @compileError("Signature of provided function: `" ++ @typeName(signature) ++ "`\nDoes not match required signature: `" ++ @typeName(REQUIRED_SIGNATURE) ++ "`");
            }

            comptime {
                const ty = @TypeOf(ac);
                const acinfo = @typeInfo(ty);

                if (acinfo == .Pointer)
                    @compileError("Expected count of arguments needed for the function: " ++ field.name);

                if (acinfo != .ComptimeInt)
                    @compileError("Expected args count to be comptime integer");
            }

            try map.put(field.name, .{
                .f = ptr,
                .ac = @as(usize, ac)
            });
        }

        return .{.map = map};
    }

    pub inline fn deinit(self: *Self) void {
        self.map.deinit();
    }
};
