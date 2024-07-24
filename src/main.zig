const std        = @import("std");
const vm_mod     = @import("vm.zig");
const inst_mod   = @import("inst.zig");
const flag_mod   = @import("flag.zig");
const lexer_mod  = @import("lexer.zig");
const NaNBox     = @import("NaNBox.zig").NaNBox;
const Parser     = @import("parser.zig").Parser;
const Natives    = @import("natives.zig").Natives;

const Flag       = flag_mod.Flag;
const FlagParser = flag_mod.Parser;

const Vm         = vm_mod.Vm;
const LabelMap   = vm_mod.LabelMap;
const InstMap    = vm_mod.InstMap;
const Program    = vm_mod.Program;

const Lexer      = lexer_mod.Lexer;
const Loc        = lexer_mod.Token.Loc;

const INST_CAP   = inst_mod.INST_CAP;
const Inst       = inst_mod.Inst;
const InstValue  = inst_mod.InstValue;

const exit       = std.process.exit;

const out_flag = Flag([]const u8, "-o", "--output", .{
    .help = "path to bin output file",
}).new();

const src_flag = Flag([]const u8, "-p", "--path", .{
    .help = "path to src file",
    .mandatory = true,
}).new();

fn write_program(file_path: []const u8, program: []const Inst) !void {
    std.debug.print("{}\n", .{program.len});
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    for (program) |inst| {
        _ = try file.write(&try inst.to_bytes());
    }
}

fn get_program(file_path: []const u8, alloc: std.mem.Allocator) !Parser.Parsed {
    return if (std.mem.endsWith(u8, file_path, ".asm")) {
        var lexer = Lexer.init(file_path, alloc) catch exit(1);
        defer lexer.deinit();

        var parser = Parser.new(lexer.file_path, alloc);

        return parser.parse(&lexer.tokens) catch exit(1);
    } else {
        var ip: u32 = 0;
        var bp: usize = 0;
        var lm = LabelMap.init(alloc);
        var im = InstMap.init(alloc);
        var program = Program.init(alloc);

        const file = try std.fs.cwd().readFileAlloc(alloc, file_path, 128 * 128);

        while (bp < file.len) : (bp += INST_CAP) {
            const chunk = file[bp..bp + INST_CAP];
            const inst = try Inst.from_bytes(chunk);
            if (inst.type == .label) {
                try lm.put(switch (inst.value) {
                    .Str => |str| str,
                    else => unreachable,
                }, ip);
            }

            try im.put(ip, Loc {.row = 68, .col = 68});
            try program.append(try Inst.from_bytes(chunk));
            ip += 1;
        }

        return Parser.Parsed {
            .program = program,
            .lm = lm,
            .im = im,
        };
    };
}

fn push_69(vm: *Vm) !void {
    try vm.stack.pushBack(NaNBox.from(i64, 69));
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var natives = Natives.init(arena.allocator());
    try natives.append("push_69", push_69);

    var flag_parser = try FlagParser.init();
    defer flag_parser.deinit();

    const file_path = flag_parser.parse(src_flag).?;
    const parsed = try get_program(file_path, arena.allocator());
    const program = parsed.program;
    defer program.deinit();

    if (flag_parser.parse(out_flag)) |file_path_| {
        try write_program(file_path_, program.items);
    }

    var im = parsed.im;
    var lm = parsed.lm;

    var vm = try Vm.init(program.items, file_path, &lm, &im, &natives, arena.allocator());
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
