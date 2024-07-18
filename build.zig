const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const release = b.option(bool, "release", "Build in release mode") orelse false;

    _ = b.addModule("vmz", .{
        .root_source_file = .{ .path = "src/main.zig" },
        .imports = &.{},
    });

    const bin = b.addExecutable(.{
        .name = "vmz",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = if (release) .ReleaseFast else .Debug,
        .target = target,
    });

    b.installArtifact(bin);
}
