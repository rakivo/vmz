const std = @import("std");
const vmz = @import("src/vmz.zig");

const Vm = vmz.Vm;
const Natives = vmz.Natives;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var natives = try Natives.init(arena.allocator(), .{});

    var vm = try vmz.init(arena.allocator(), &natives);
    try vm.execute_program();
}
