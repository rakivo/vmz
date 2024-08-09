const std = @import("std");
const Buf = @import("vm.zig").Buf;
const InstValueType = @import("inst.zig").InstValueType;

pub const Type = enum(u8) {
    I8,
    U8,
    I64,
    I32,
    U64,
    U32,
    F64,
    F32,
    Str,
    Bool,
    BufPtr,
    InstValueType,
};

pub const NaNBox = union {
    v: f64,

    const Self = @This();

    const EXP_MASK: u64 = ((1 << 11) - 1) << 52;
    const TYPE_MASK: u64 = ((1 << 4) - 1) << 48;
    const VALUE_MASK: u64 = (1 << 48) - 1;

    const SUPPORTED_TYPES_MSG = "Supported types: " ++ @typeName(i64) ++ ", " ++ @typeName(u64) ++ ", " ++ @typeName(f64) ++ ", " ++ @typeName(u8) ++ ", []u8";

    pub inline fn mkInf() f64 {
        return @bitCast(EXP_MASK);
    }

    inline fn isNaN(self: *const Self) bool {
        return self.v != self.v;
    }

    pub inline fn setType(x: f64, ty: Type) f64 {
        var bits: u64 = @bitCast(x);
        const tv: u64 = @intFromEnum(ty);
        bits = (bits & ~TYPE_MASK) | ((tv & 0xF) << 48);
        return @bitCast(bits);
    }

    pub inline fn getType(self: *const Self) Type {
        if (!self.isNaN()) return .F64;
        const bits: u64 = @bitCast(self.v);
        return @enumFromInt((bits & TYPE_MASK) >> 48);
    }

    pub inline fn setValue(x: f64, value: i64) f64 {
        var bits: u64 = @bitCast(x);
        bits = (bits & ~VALUE_MASK) | (@abs(value) & VALUE_MASK) | if (value < 0) @as(u64, 1 << 63) else 0;
        return @bitCast(bits);
    }

    pub inline fn getValue(self: *const Self) i64 {
        const bits: u64 = @bitCast(self.v);
        const value: i64 = @intCast(bits & VALUE_MASK);
        return if ((bits & (1 << 63)) != 0) -value else value;
    }

    pub inline fn is(self: *const Self, comptime T: type) bool {
        return switch (T) {
            f64 => !self.isNaN(),
            i64 => self.isNaN() and self.getType() == .I64,
            u64 => self.isNaN() and self.getType() == .U64,
            u8  => self.isNaN() and self.getType() == .U8,
            []u8, []const u8 => self.isNaN() and self.getType() == .Str,
            inline else => @compileError("Unsupported type: " ++ @typeName(T) ++ "\n" ++ SUPPORTED_TYPES_MSG)
        };
    }

    pub inline fn as(self: *const Self, comptime T: type) T {
        return switch (T) {
            f64 => self.v,
            i64 => self.getValue(),
            bool => if (self.getValue() > 0) true else false,
            u64 => @intCast(self.getValue()),
            i32 => @intCast(self.getValue()),
            u32 => @intCast(self.getValue()),
            f32 => self.v,
            i8  => @intCast(self.getValue()),
            u8  => @intCast(self.getValue()),
            usize => @intCast(self.getValue()),
            InstValueType => @enumFromInt(self.getValue()),
            inline else => @compileError("Unsupported type: " ++ @typeName(T) ++ "\n" ++ SUPPORTED_TYPES_MSG),
        };
    }

    pub inline fn from(comptime T: type, v: T) Self {
        return switch (T) {
            f64 => .{ .v = v },
            u64 => .{ .v = Self.setType(Self.setValue(Self.mkInf(), @intCast(v)), .U64) },
            i64 => .{ .v = Self.setType(Self.setValue(Self.mkInf(), v), .I64) },
            u8  => .{ .v = Self.setType(Self.setValue(Self.mkInf(), @intCast(v)), .U8) },
            i8  => .{ .v = Self.setType(Self.setValue(Self.mkInf(), @intCast(v)), .I8) },
            bool => .{ .v = Self.setType(Self.setValue(Self.mkInf(), if (v) 1 else 0), .Bool) },
            []u8, []const u8 => .{ .v = Self.setType(Self.setValue(Self.mkInf(), @intCast(v.len)), .Str) },
            Buf => .{ .v = Self.setType(Self.setValue(Self.mkInf(), @as(i64, @intCast(@intFromPtr(v.ptr)))), .BufPtr) },
            inline else => @compileError("Unsupported type: " ++ @typeName(T) ++ "\n" ++ SUPPORTED_TYPES_MSG),
        };
    }

    pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try switch(self.getType()) {
            .U8  => writer.print("{d}", .{ self.as(u8) }),
            .I8  => writer.print("{d}", .{ self.as(i8) }),
            .F64 => writer.print("{d}f", .{ self.v }),
            .F32 => writer.print("{d}f", .{ self.v }),
            .I64 => writer.print("{d}", .{ self.as(i64) }),
            .U64 => writer.print("{d}", .{ self.as(u64) }),
            .U32 => writer.print("{d}", .{ self.as(u32) }),
            .I32 => writer.print("{d}", .{ self.as(i32) }),
            .Bool => writer.print("{}", .{ self.as(bool) }),
            .Str => writer.print("Str size: {d}", .{ self.as(usize) }),
            .BufPtr => writer.print("Buf Slice Len: {}", .{ self.as(u64) }),
            .InstValueType => writer.print("{}", .{ self.as(InstValueType) }),
        };
    }
};
