const std    = @import("std");
const inst   = @import("inst.zig");
const vm     = @import("vm.zig");
const lexer  = @import("lexer.zig");
const NaNBox = @import("NaNBox.zig").NaNBox;

const LabelMap      = vm.LabelMap;
const InstMap       = vm.InstMap;
const Program       = vm.Program;

const Inst          = inst.Inst;
const InstType      = inst.InstType;
const InstValue     = inst.InstValue;

const Loc           = lexer.Token.Loc;
const Token         = lexer.Token;
const MacroMap      = lexer.MacroMap;
const LinizedTokens = lexer.LinizedTokens;
const report_err    = lexer.Lexer.report_err;

pub const Parser = struct {
    file_path: []const u8,
    alloc: std.mem.Allocator,

    const Self = @This();

    pub const Error = error {
        NO_OPERAND,
        INVALID_TYPE,
        NO_ENTRY_POINT,
        FAILED_TO_PARSE,
        UNDEFINED_SYMBOL,
    };

    fn parse_inst(ty: InstType, operand: Token) !Inst {
        return switch (operand.type) {
            .char => Inst.new(ty, InstValue.new(u8, operand.str[0])),
            .str, .label, .literal => Inst.new(ty, InstValue.new([]const u8, operand.str)),
            .int => {
                var base: u8 = undefined;
                var str: []const u8 = undefined;
                if (std.mem.startsWith(u8, operand.str, "0x")) {
                    str = operand.str[2..];
                    base = 16;
                } else {
                    str = operand.str;
                    base = 10;
                }

                const int = std.fmt.parseInt(i64, str, base) catch |err| {
                    std.debug.print("Failed parsing int: {s}: {}\n", .{operand.str, err});
                    return report_err(operand.loc, Error.FAILED_TO_PARSE);
                };

                if (int >= 0) {
                    return if (ty == .push)
                        Inst.new(ty, InstValue.new(NaNBox, NaNBox.from(u64, @intCast(int))))
                    else
                        Inst.new(ty, InstValue.new(u64, @intCast(int)));
                } else {
                    return if (ty == .push)
                        Inst.new(ty, InstValue.new(NaNBox, NaNBox.from(i64, @intCast(int))))
                    else
                        Inst.new(ty, InstValue.new(i64, int));
                }
            },
            .float => {
                const float = std.fmt.parseFloat(f64, operand.str) catch |err| {
                    std.debug.print("Failed parsing int: {s}: {}\n", .{operand.str, err});
                    return report_err(operand.loc, Error.FAILED_TO_PARSE);
                };

                return if (ty == .push)
                    return Inst.new(ty, InstValue.new(NaNBox, NaNBox.from(f64, float)))
                else
                    return Inst.new(ty, InstValue.new(f64, float));
            }
        };
    }

    pub inline fn new(file_path: []const u8, alloc: std.mem.Allocator) Self {
        return .{
            .file_path = file_path,
            .alloc = alloc,
        };
    }

    pub const Parsed = struct {
        ip: u64,
        im: InstMap,
        lm: LabelMap,
        program: Program,

        pub inline fn deinit(parsed: *Parsed) void {
            parsed.lm.deinit();
            parsed.im.deinit();
            parsed.program.deinit();
        }
    };

    pub fn parse(self: *Self, ts: *LinizedTokens) !Parsed {
        var ip: u32 = 0;
        var entry_point: ?u64 = null;
        var lm = LabelMap.init(self.alloc);
        var im = InstMap.init(self.alloc);
        var program = Program.init(self.alloc);

        for (ts.items) |line| {
            var idx: u16 = 0;
            while (idx < line.len) : (idx += 1) {
                if (line[idx].type == .label) {
                    if (std.mem.eql(u8, line[idx].str, "_start"))
                        entry_point = ip;

                    try program.append(Inst.new(.label, InstValue.new([]const u8, line[idx].str)));
                    try im.put(ip, line[idx].loc);
                    try lm.put(line[idx].str, ip);
                    ip += 1;
                    continue;
                }

                const tyo = InstType.try_from_str(line[idx].str);
                if (tyo == null)
                    return report_err(line[idx].loc, Error.UNDEFINED_SYMBOL);

                const ty = tyo.?;
                if (!ty.arg_required()) {
                    try program.append(Inst.new(ty, inst.None));
                    try im.put(ip, line[idx].loc);
                    ip += 1;
                    continue;
                }

                if (idx + 1 > line.len) return report_err(line[idx].loc, Error.NO_OPERAND);
                idx += 1;

                if (idx >= line.len)
                    return report_err(line[idx - 1].loc, Error.NO_OPERAND);

                const operand = line[idx];
                if (std.mem.indexOf(Token.Type,
                                    ty.expected_types(),
                                    &[_]Token.Type{operand.type}) == null)
                {
                    return report_err(operand.loc, Error.INVALID_TYPE);
                }

                try program.append(try parse_inst(ty, operand));
                try im.put(ip, line[idx].loc);
                ip += 1;
            }
        }

        return Parsed {
            .ip = if (entry_point) |e| e else {
                return report_err(Loc.new(68, 68, self.file_path), Error.NO_ENTRY_POINT);
            },
            .lm = lm,
            .im = im,
            .program = program,
        };
    }
};
