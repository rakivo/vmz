const std = @import("std");
const vmz = @import("vmz/vmz.zig");
const Vm = vmz.vm.Vm;

const raylib = @cImport(@cInclude("raylib.h"));

const NaNBox = vmz.NaNBox;

// InitWindow(int width, int height, const char *title);
pub fn init_window(vm: *Vm) anyerror!void {
    const str_len = vm.stack.pop().?.as(u64);

    var str = std.ArrayList(u8).init(vm.alloc);
    for (0..str_len) |_| {
        try str.append(vm.stack.pop().?.as(u8));
    }

    for (0..str.items.len / 2) |i| {
        const temp = str.items[i];
        str.items[i] = str.items[str.items.len - 1 - i];
        str.items[str.items.len - 1 - i] = temp;
    }

    try str.append(0);

    const h = vm.stack.pop().?.as(i32);
    const w = vm.stack.pop().?.as(i32);
    raylib.InitWindow(w, h, @ptrCast(str.items));
}

// void CloseWindow(void)
pub fn close_window(_: *Vm) anyerror!void {
    raylib.CloseWindow();
}

// void BeginDrawing(void)
pub fn begin_drawing(_: *Vm) anyerror!void {
    raylib.BeginDrawing();
}

// void EndDrawing(void)
pub fn end_drawing(_: *Vm) anyerror!void {
    raylib.EndDrawing();
}

fn color_from_u64(v: u64) raylib.Color {
    return raylib.Color {
        .r = @intCast((v >> 16) & 0xFF),
        .g = @intCast((v >> 8) & 0xFF),
        .b = @intCast(v & 0xFF),
        .a = @intCast((v >> 24) & 0xFF),
    };
}

// void ClearBackground(Color color)
pub fn clear_background(vm: *Vm) anyerror!void {
    const v = vm.stack.pop().?.as(u64);
    const color = color_from_u64(v);
    raylib.ClearBackground(color);
}

// int GetScreenHeight(void)
pub fn get_screen_height(vm: *Vm) anyerror!void {
    const height: u64 = @intCast(raylib.GetScreenHeight());
    const nan = NaNBox.from(u64, height);
    vm.stack.append(nan);
}

// int GetScreenWidth(void)
pub fn get_screen_width(vm: *Vm) anyerror!void {
    const height: u64 = @intCast(raylib.GetScreenWidth());
    const nan = NaNBox.from(u64, height);
    vm.stack.append(nan);
}

// void SetTargetFPS(int fps)
pub fn set_target_fps(vm: *Vm) anyerror!void {
    const fps: i32 = @intCast(vm.stack.pop().?.as(u64));
    raylib.SetTargetFPS(fps);
}

// void DrawText(const char *text, int posX, int posY, int fontSize, Color color)
pub fn draw_text(vm: *Vm) anyerror!void {
    const v = vm.stack.pop().?.as(u64);
    const color = color_from_u64(v);

    const size: i32 = @intCast(vm.stack.pop().?.as(u64));

    const y: i32 = @intCast(vm.stack.pop().?.as(u64));
    const x: i32 = @intCast(vm.stack.pop().?.as(u64));

    const str_len = vm.stack.pop().?.as(u64);

    var str = std.ArrayList(u8).init(vm.alloc);
    for (0..str_len) |_| {
        try str.append(vm.stack.pop().?.as(u8));
    }

    for (0..str.items.len / 2) |i| {
        const temp = str.items[i];
        str.items[i] = str.items[str.items.len - 1 - i];
        str.items[str.items.len - 1 - i] = temp;
    }

    try str.append(0);

    raylib.DrawText(@ptrCast(str.items), x, y, size, color);
}

// bool WindowShouldClose(void)
pub fn window_should_close(vm: *Vm) anyerror!void {
    const b: bool = raylib.WindowShouldClose();
    vm.stack.append(NaNBox.from(bool, b));
}
