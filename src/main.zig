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
const panic      = vm_mod.panic;
const InstMap    = vm_mod.InstMap;
const Program    = vm_mod.Program;
const LabelMap   = vm_mod.LabelMap;

const Lexer      = lexer_mod.Lexer;
const Loc        = lexer_mod.Token.Loc;

const INST_CAP   = inst_mod.INST_CAP;
const Inst       = inst_mod.Inst;
const InstValue  = inst_mod.InstValue;
const InstType   = inst_mod.InstType;

const exit = std.process.exit;

const out_flag = Flag([]const u8, "-o", "--output", .{
    .help = "path to bin output file",
}).new();

const src_flag = Flag([]const u8, "-p", "--path", .{
    .help = "path to src file",
    .mandatory = true,
}).new();

const include_flag = Flag([]const u8, "-I", "--include", .{
    .help = "include path",
}).new();

fn write_program(file_path: []const u8, program: []const Inst) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    for (program) |inst| {
        _ = try file.write(&try inst.to_bytes());
    }
}

fn get_program(file_path: []const u8, alloc: std.mem.Allocator, flag_parser: *FlagParser) !Parser.Parsed {
    return if (std.mem.endsWith(u8, file_path, ".asm")) {
        var lexer = Lexer.init(file_path, alloc, flag_parser.parse(include_flag));
        defer lexer.deinit();

        const content = try Lexer.read_file(file_path, alloc);
        try lexer.lex_file(content);

        var parser = Parser.new(file_path, alloc);
        return parser.parse(&lexer.tokens) catch exit(1);
    } else {
        var ip: u32 = 0;
        var bp: usize = 0;
        var entry_point: ?u64 = 0;
        var lm = LabelMap.init(alloc);
        var im = InstMap.init(alloc);
        var program = Program.init(alloc);

        const file = try std.fs.cwd().readFileAlloc(alloc, file_path, 128 * 128);
        if (file[0] < 0 or file[0] > @intFromEnum(InstType.halt))
            panic("ERROR: Failed to get type of instruction from bytes", .{});

        while (bp < file.len) : (bp += INST_CAP) {
            const chunk = file[bp..bp + INST_CAP];
            const inst = try Inst.from_bytes(chunk);
            if (inst.type == .label) {
                if (std.mem.eql(u8, inst.value.Str, "_start"))
                    entry_point = ip;

                try lm.put(inst.value.Str, ip);
            }

            try im.put(ip, Loc {.row = 68, .col = 68, .file_path = file_path});
            try program.append(try Inst.from_bytes(chunk));
            ip += 1;
        }

        return Parser.Parsed {
            .lm = lm,
            .im = im,
            .ip = if (entry_point) |e| e else {
                return Parser.report_err(Loc.new(68, 68, file_path), Parser.Error.NO_ENTRY_POINT);
            },
            .program = program,
        };
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var natives = Natives.init(arena.allocator());

    var flag_parser = try FlagParser.init(arena.allocator());
    defer flag_parser.deinit();

    const file_path = flag_parser.parse(src_flag).?;

    var parsed = try get_program(file_path, arena.allocator(), &flag_parser);
    defer parsed.deinit();

    if (flag_parser.parse(out_flag)) |file_path_| {
        try write_program(file_path_, parsed.program.items);
    }

    var vm = try Vm.init(&parsed, &natives, arena.allocator());
    defer vm.deinit();

    try vm.execute_program();
}
