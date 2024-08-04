const std = @import("std");

const vmz    = @import("vmz/vmz.zig");
const raylib = @import("raylib.zig");

const Natives = vmz.Natives;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var natives = try Natives.init(arena.allocator(), .{
        .draw_text           = .{ raylib.draw_text,           5 },
        .init_window         = .{ raylib.init_window,         3 },
        .close_window        = .{ raylib.close_window,        0 },
        .end_drawing         = .{ raylib.end_drawing,         0 },
        .begin_drawing       = .{ raylib.begin_drawing,       0 },
        .set_target_fps      = .{ raylib.set_target_fps,      1 },
        .clear_background    = .{ raylib.clear_background,    1 },
        .get_screen_width    = .{ raylib.get_screen_width,    0 },
        .get_screen_height   = .{ raylib.get_screen_height,   0 },
        .window_should_close = .{ raylib.window_should_close, 0 },
    });
    defer natives.deinit();

    var vm = try vmz.init(arena.allocator(), &natives);
    defer vm.deinit();

    try vm.execute_program();
}
