const std        = @import("std");
const vm_mod     = @import("vm.zig");
const inst_mod   = @import("inst.zig");
const Lexer      = @import("lexer.zig").Lexer;
const FlagParser = @import("flag.zig").Parser;
const Parser     = @import("parser.zig").Parser;
const NaNBox     = @import("NaNBox.zig").NaNBox;

const Vm        = vm_mod.Vm;
const Program   = vm_mod.program;

const Inst      = inst_mod.Inst;
const InstValue = inst_mod.InstValue;

const exit = std.process.exit;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var flag_parser = try FlagParser.init();
    defer flag_parser.deinit();

    var lexer = Lexer.init(&flag_parser, arena.allocator()) catch exit(1);
    defer lexer.deinit();

    var parser = Parser.new(lexer.file_path, arena.allocator());

    const pl = parser.parse(&lexer.tokens) catch exit(1);

    const program = pl.program;
    var lm = pl.lm;

    defer program.deinit();
    defer lm.deinit();

    var vm = try Vm.new(program.items, lm, arena.allocator());
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
