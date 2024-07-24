const std        = @import("std");
const vm_mod     = @import("vm.zig");
const inst_mod   = @import("inst.zig");
const Lexer      = @import("lexer.zig").Lexer;
const FlagParser = @import("flag.zig").Parser;
const NaNBox     = @import("NaNBox.zig").NaNBox;
const Parser     = @import("parser.zig").Parser;
const Natives    = @import("natives.zig").Natives;

const Vm        = vm_mod.Vm;
const Program   = vm_mod.program;

const Inst      = inst_mod.Inst;
const InstValue = inst_mod.InstValue;

const exit = std.process.exit;

fn push_69(vm: *Vm) !void {
    try vm.stack.pushBack(NaNBox.from(i64, 69));
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var natives = Natives.init(arena.allocator());
    try natives.append("push_69", push_69);

    var flag_parser = try FlagParser.init();
    defer flag_parser.deinit();

    var lexer = Lexer.init(&flag_parser, arena.allocator()) catch exit(1);
    defer lexer.deinit();

    var parser = Parser.new(lexer.file_path, arena.allocator());

    const parsed = parser.parse(&lexer.tokens) catch exit(1);

    const program = parsed.program;
    defer program.deinit();

    var im = parsed.im;
    var lm = parsed.lm;

    var vm = try Vm.init(program.items, parser.file_path, &lm, &im, &natives, arena.allocator());
    defer vm.deinit();

    var start: i64 = 0;
    comptime if (vm_mod.DEBUG) {
        start = std.time.microTimestamp();
    };

    try vm.execute_program();

    comptime if (vm_mod.DEBUG) {
        const elapsed = std.time.microTimestamp() - start;
        std.debug.print("Execution of program took: {d}μs\n", .{elapsed});
    };
}
