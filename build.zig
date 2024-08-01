const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const lib = b.addStaticLibrary(.{
        .name = "vmz",
        .root_source_file = .{ .cwd_relative = "src/vmz.zig" },
        .optimize = .ReleaseFast,
        .target = target,
    });

    b.installArtifact(lib);
}
