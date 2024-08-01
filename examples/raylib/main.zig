const std = @import("std");

const vmz    = @import("vmz/vmz.zig");
const raylib = @import("raylib.zig");

const Natives = vmz.Natives;

const draw_text         = raylib.draw_text;
const init_window       = raylib.init_window;
const end_drawing       = raylib.end_drawing;
const begin_drawing     = raylib.begin_drawing;
const set_target_fps    = raylib.set_target_fps;
const clear_background  = raylib.clear_background;
const get_screen_width  = raylib.get_screen_width;
const get_screen_height = raylib.get_screen_height;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var natives = try Natives.init(arena.allocator(), .{
        .draw_text = draw_text,
        .init_window = init_window,
        .end_drawing = end_drawing,
        .begin_drawing = begin_drawing,
        .set_target_fps = set_target_fps,
        .clear_background = clear_background,
        .get_screen_width = get_screen_width,
        .get_screen_height = get_screen_height
    });
    defer natives.deinit();

    var vm = try vmz.init(arena.allocator(), &natives);
    defer vm.deinit();

    try vm.execute_program();
}
