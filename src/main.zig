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

const pi = [_]Inst{
    Inst.new(.push, InstValue.new(NaNBox, NaNBox.from(f64, 4.0))),
    Inst.new(.push, InstValue.new(NaNBox, NaNBox.from(f64, 3.0))),
    Inst.new(.push, InstValue.new(NaNBox, NaNBox.from(u64, 750000))),
    Inst.new(.swap, InstValue.new(u64, 2)),
    Inst.new(.push, InstValue.new(NaNBox, NaNBox.from(f64, 4.0))),
    Inst.new(.dup,  InstValue.new(u64, 2)),
    Inst.new(.push, InstValue.new(NaNBox, NaNBox.from(f64, 2.0))),
    Inst.new(.fadd, inst_mod.None),
    Inst.new(.swap, InstValue.new(u64, 3)),
    Inst.new(.fdiv, inst_mod.None),
    Inst.new(.fsub, inst_mod.None),
    Inst.new(.push, InstValue.new(NaNBox, NaNBox.from(f64, 4.0))),
    Inst.new(.dup,  InstValue.new(u64, 2)),
    Inst.new(.push, InstValue.new(NaNBox, NaNBox.from(f64, 2.0))),
    Inst.new(.fadd, inst_mod.None),
    Inst.new(.swap, InstValue.new(u64, 3)),
    Inst.new(.fdiv, inst_mod.None),
    Inst.new(.fadd, inst_mod.None),
    Inst.new(.swap, InstValue.new(u64, 2)),
    Inst.new(.dec,  inst_mod.None),
    Inst.new(.push, InstValue.new(NaNBox, NaNBox.from(u64, 0))),
    Inst.new(.cmp,  inst_mod.None),
    Inst.new(.jne,  InstValue.new(u64, 3)),
    Inst.new(.pop,  inst_mod.None),
    Inst.new(.pop,  inst_mod.None),
    Inst.new(.dmp,  inst_mod.None),
};

const str = [_]Inst{
    Inst.new(.push, InstValue.new([]const u8, "hello world")),
    Inst.new(.dmp,  inst_mod.None),
};

const cmp = [_]Inst{
    Inst.new(.push, InstValue.new(NaNBox, NaNBox.from(u64, 69))),
    Inst.new(.push, InstValue.new(NaNBox, NaNBox.from(u64, 420))),
    Inst.new(.cmp,  inst_mod.None),
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var flag_parser = try FlagParser.init();
    defer flag_parser.deinit();

    var lexer = Lexer.init(&flag_parser, &arena) catch exit(1);
    defer lexer.deinit();

    var parser = Parser.new(lexer.file_path, arena.allocator());

    const program = parser.parse(&lexer.tokens) catch exit(1);
    defer program.deinit();

    const start = std.time.microTimestamp();

    var vm = try Vm.new(program.items, arena.allocator());
    defer vm.deinit();

    try vm.execute_program();

    const elapsed = std.time.microTimestamp() - start;
    std.debug.print("Execution of program took: {d}μs\n", .{elapsed});
}
