const std = @import("std");

pub const vm      = @import("vm.zig");
pub const inst    = @import("inst.zig");
pub const flag    = @import("flag.zig");
pub const lexer   = @import("lexer.zig");
pub const NaNBox  = @import("NaNBox.zig").NaNBox;
pub const Parser  = @import("parser.zig").Parser;
pub const Natives = @import("natives.zig").Natives;

const Flag               = flag.Flag;
const FlagParser         = flag.Parser;

const Vm                 = vm.Vm;
const panic              = vm.panic;
const InstMap            = vm.InstMap;
const Program            = vm.Program;
const LabelMap           = vm.LabelMap;

const Loc                = lexer.Token.Loc;
const Lexer              = lexer.Lexer;
const report_err         = lexer.Lexer.report_err;

const Inst               = inst.Inst;
const InstValue          = inst.InstValue;
const CHUNK_SIZE         = inst.CHUNK_SIZE;
const STRING_PLACEHOLDER = inst.STRING_PLACEHOLDER;
const InstType           = inst.InstType;
const InstValueType      = inst.InstValueType;

const exit               = std.process.exit;

const SECTION_SEPARATOR: [1]u8 = [1]u8{';'};
const ASM_FILE_EXTENSION: []const u8 = ".asm";
const ENTRY_POINT_NAME: []const u8 = "_start";

const out_flag = Flag([]const u8, "-o", "--output", .{
    .help = "path to bin output file"
}).new();

const src_flag = Flag([]const u8, "-p", "--path", .{
    .help = "path to src file",
    .mandatory = true,
}).new();

const include_flag = Flag([]const u8, "-I", "--include", .{
    .help = "include path"
}).new();

fn write_program(file_path: []const u8, program: []const Inst) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    for (program) |inst_| {
        if (inst_.value != .Str) continue;
        const str = inst_.value.Str;
        const str_len: u8 = @intCast(str.len);
        _ = try file.write(&[_]u8{str_len});
        _ = try file.write(str);
    }

    _ = try file.write(&SECTION_SEPARATOR);

    for (program) |inst_| {
        var ret: [CHUNK_SIZE]u8 = undefined;
        ret[0] = @intFromEnum(inst_.type);
        ret[1] = @intFromEnum(inst_.value);

        if (inst_.value != .Str) {
            switch (inst_.value) {
                .NaN => |nan| std.mem.copyForwards(u8, ret[2..], &std.mem.toBytes(nan.v)),
                .I64 => |int| std.mem.copyForwards(u8, ret[2..], &std.mem.toBytes(int)),
                .U64 => |int| std.mem.copyForwards(u8, ret[2..], &std.mem.toBytes(int)),
                .F64 => |f|   std.mem.copyForwards(u8, ret[2..], &std.mem.toBytes(f)),
                .Str => unreachable,
                else => {},
            }
        } else {
            const place_holder: *const [8:0]u8 = STRING_PLACEHOLDER;
            std.mem.copyForwards(u8, ret[2..], place_holder);
        }

        _ = try file.write(&ret);
    }
}

fn get_program(file_path: []const u8, alloc: std.mem.Allocator, flag_parser: *FlagParser) !Parser.Parsed {
    return if (std.mem.endsWith(u8, file_path, ASM_FILE_EXTENSION)) {
        var lexer_ = Lexer.init(file_path, alloc, flag_parser.parse(include_flag));
        defer lexer_.deinit();

        const content = try Lexer.read_file(file_path, alloc);
        try lexer_.lex_file(content);

        var parser = Parser.new(file_path, alloc);
        return parser.parse(&lexer_.tokens) catch exit(1);
    } else {
        var ip: u32 = 0;
        var bp: usize = 0;
        var entry_point: ?u64 = 0;
        var lm = LabelMap.init(alloc);
        var im = InstMap.init(alloc);
        var program = Program.init(alloc);

        const file = try std.fs.cwd().readFileAlloc(alloc, file_path, 128 * 128);
        if (file.len <= 0)
            panic("File is empty", .{});

        if (file[0] < 0 or file[0] > @intFromEnum(InstType.halt))
            panic("ERROR: Failed to get type of instruction from bytes", .{});

        var strs = std.ArrayList([]const u8).init(alloc);
        while (file[bp] != SECTION_SEPARATOR[0]) {
            const str_len = file[bp];
            bp += 1;
            const str = file[bp..bp + str_len];
            bp += str_len;
            try strs.append(str);
        }

        // Skip the SECTION_SEPARATOR
        bp += 1;

        var str_count: usize = 0;
        while (bp < file.len) : (bp += CHUNK_SIZE) {
            const chunk = file[bp..bp + CHUNK_SIZE];
            if (chunk[1] != @intFromEnum(InstValueType.Str)) {
                const inst_ = try Inst.from_bytes(chunk);
                try im.put(ip, Loc.new(68, 68, file_path));
                try program.append(inst_);
            } else {
                const inst_type: InstType = @enumFromInt(chunk[0]);
                const inst_value = InstValue {
                    .Str = strs.items[str_count]
                };

                str_count += 1;

                const inst_ = Inst {
                    .type = inst_type,
                    .value = inst_value
                };

                if (inst_.type == .label) {
                    if (std.mem.eql(u8, inst_.value.Str, ENTRY_POINT_NAME))
                        entry_point = ip;

                    try lm.put(inst_.value.Str, ip);
                }

                try im.put(ip, Loc.new(68, 68, file_path));
                try program.append(inst_);
            }

            ip += 1;
        }

        return Parser.Parsed {
            .lm = lm,
            .im = im,
            .ip = entry_point orelse {
                return report_err(Loc.new(68, 68, file_path), Parser.Error.NO_ENTRY_POINT);
            },
            .program = program,
        };
    };
}

pub fn init(allocator: std.mem.Allocator, natives: *Natives) !Vm {
    var flag_parser = try FlagParser.init(allocator);
    defer flag_parser.deinit();

    const file_path = flag_parser.parse(src_flag).?;

    var parsed = try get_program(file_path, allocator, &flag_parser);

    if (flag_parser.parse(out_flag)) |file_path_|
        try write_program(file_path_, parsed.program.items);

    return try Vm.init(parsed, natives, allocator);
}
