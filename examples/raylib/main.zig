const std = @import("std");

const vmz    = @import("vmz/vmz.zig");
const raylib = @import("raylib.zig");

const Natives = vmz.Natives;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var natives = try Natives.init(arena.allocator(), .{
        .draw_text           = raylib.draw_text,
        .init_window         = raylib.init_window,
        .end_drawing         = raylib.end_drawing,
        .begin_drawing       = raylib.begin_drawing,
        .set_target_fps      = raylib.set_target_fps,
        .clear_background    = raylib.clear_background,
        .get_screen_width    = raylib.get_screen_width,
        .get_screen_height   = raylib.get_screen_height,
        .window_should_close = raylib.window_should_close
    });
    defer natives.deinit();

    var vm = try vmz.init(arena.allocator(), &natives);
    defer vm.deinit();

    try vm.execute_program();
}
