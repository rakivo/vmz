const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    _ = b.addModule("vmz", .{
        .root_source_file = .{ .path = "src/main.zig" },
        .imports = &.{},
    });

    const bin = b.addExecutable(.{
        .name = "vmz",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = .ReleaseFast,
        .target = target,
    });

    b.installArtifact(bin);
}
