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

    pub inline fn report_err(loc: Loc, err: anyerror) anyerror {
        std.debug.print("{s}:{d}:{d}: ERROR: {}\n", .{
            loc.file_path,
            loc.row + 1,
            loc.col + 1,
            err,
        });
        return err;
    }

    fn parse_inst(_: *Self, ty: InstType, operand_str: Token) !Inst {
        switch (operand_str.type) {
            .str, .label, .literal => return Inst.new(ty, InstValue.new([]const u8, operand_str.str)),
            .char => return Inst.new(ty, InstValue.new(u8, operand_str.str[0])),
            .int => {
                const int = std.fmt.parseInt(i64, operand_str.str, 10) catch |err| {
                    std.debug.print("Failed parsing int: {s}: {}\n", .{operand_str.str, err});
                    return report_err(operand_str.loc, Error.FAILED_TO_PARSE);
                };
                if (int >= 0) {
                    if (ty == .push) {
                        return Inst.new(ty, InstValue.new(NaNBox, NaNBox.from(u64, @intCast(int))));
                    } else
                        return Inst.new(ty, InstValue.new(u64, @intCast(int)));
                } else {
                    if (ty == .push) {
                        return Inst.new(ty, InstValue.new(NaNBox, NaNBox.from(i64, @intCast(int))));
                    } else
                        return Inst.new(ty, InstValue.new(i64, int));
                }
            },
            .float => {
                const float = std.fmt.parseFloat(f64, operand_str.str) catch |err| {
                    std.debug.print("Failed parsing int: {s}: {}\n", .{operand_str.str, err});
                    return report_err(operand_str.loc, Error.FAILED_TO_PARSE);
                };
                if (ty == .push) {
                    return Inst.new(ty, InstValue.new(NaNBox, NaNBox.from(f64, float)));
                } else
                    return Inst.new(ty, InstValue.new(f64, float));
            }
        }
    }

    pub fn new(file_path: []const u8, alloc: std.mem.Allocator) Self {
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

                try program.append(try self.parse_inst(ty, operand));
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
