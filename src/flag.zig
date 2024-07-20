// Copyright 2024 Mark Tyrkba <marktyrkba456@gmail.com>

// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

const std  = @import("std");

const mem     = std.mem;
const heap    = std.heap;
const process = std.process;
const exit    = process.exit;

pub fn Flag(comptime T: type, comptime short_: []const u8, comptime long_: []const u8, comptime flag: anytype) type {
    return struct {
        short: []const u8,
        long:  []const u8,

        type: type = T,

        help: ?[]const u8 = null,
        default: ?T       = null,
        mandatory: bool   = false,

        const Self = @This();

        inline fn format_flag() []const u8 {
            comptime return "Short flag: " ++ short_ ++ "\nLong flag: " ++ long_;
        }

        pub inline fn new() Self {
            var help: ?[]const u8 = null;
            var default: ?T       = null;
            var mandatory: bool   = false;

            if (@hasField(@TypeOf(flag), "help"))      help      = @as(?[]const u8, @field(flag, "help"));
            if (@hasField(@TypeOf(flag), "default"))   default   = @as(?T,          @field(flag, "default"));
            if (@hasField(@TypeOf(flag), "mandatory")) mandatory = @as(bool,        @field(flag, "mandatory"));

            comptime return .{
                .short     = short_,
                .long      = long_,
                .help      = help,
                .default   = default,
                .mandatory = mandatory
            };
        }
    };
}

pub const Parser = struct {
    args:  [][:0]u8,

    const Self = @This();

    pub inline fn init() !Parser {
        return .{
            .args  = try process.argsAlloc(heap.page_allocator)
        };
    }

    pub inline fn deinit(self: Self) void {
        process.argsFree(heap.page_allocator, self.args);
    }

    fn parse_(self: *const Self, flag: anytype) ?[]const u8 {
        for (self.args, 0..) |arg, i|
            if (std.mem.eql(u8, arg, flag.short) or std.mem.eql(u8, arg, flag.long))
                if (i + 1 < self.args.len) {
                    return self.args[i + 1];
                } else return null;

        return null;
    }

    pub fn parse(self: *const Self, flag: anytype) ?flag.type {
        const str = if (self.parse_(flag)) |str| str else {
            std.debug.print("Mandatory `{s}` or `{s}` flag is not provided\n", .{flag.short, flag.long});
            exit(1);
        };
        return switch(flag.type) {
            []const u8 => @as(flag.type, str),
            i8, i16, i32, i64, i128 => return std.fmt.parseInt(flag.type, str, 10)      catch null,
            u8, u16, u32, u64, u128 => return std.fmt.parseUnsigned(flag.type, str, 10) catch null,
                f16, f32, f64, f128 => return std.fmt.parseFloat(flag.type, str)        catch null,
            else => @compileError("UNSUPPORTED TYPE: " ++ @typeName(flag.type))
        };
    }

    pub inline fn passed(self: *const Self, flag: anytype) bool {
        return if (self.parse_(flag)) |_| true else false;
    }
};
