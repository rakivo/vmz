const std      = @import("std");
const vm_mod   = @import("vm.zig");
const inst_mod = @import("inst.zig");
const NaNBox   = @import("NaNBox.zig").NaNBox;

const Vm        = vm_mod.Vm;
const Program   = vm_mod.program;

const Inst      = inst_mod.Inst;
const InstValue = inst_mod.InstValue;

const insts = [_]Inst{
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var program = try Program.new(arena.allocator(), &insts);
    defer program.deinit();

    const start = std.time.microTimestamp();

    var vm = try Vm.new(program);
    defer vm.deinit();

    try vm.execute_program();

    const elapsed = std.time.microTimestamp() - start;
    std.debug.print("Execution of program took: {d}ms\n", .{elapsed});
}
