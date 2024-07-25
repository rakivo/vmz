const std    = @import("std");
const inst   = @import("inst.zig");
const vm     = @import("vm.zig");
const lexer  = @import("lexer.zig");
const NaNBox = @import("NaNBox.zig").NaNBox;

const Inst          = inst.Inst;
const LabelMap      = vm.LabelMap;
const InstMap       = vm.InstMap;
const Program       = vm.Program;
const Loc           = lexer.Token.Loc;
const InstType      = inst.InstType;
const InstValue     = inst.InstValue;
const Token         = lexer.Token;
const LinizedTokens = lexer.LinizedTokens;

pub const Parser = struct {
    file_path: []const u8,
    alloc: std.mem.Allocator,

    const Self = @This();

    pub const Error = error {
        FAILED_TO_PARSE,
        UNDEFINED_SYMBOL,
        NO_OPERAND,
        INVALID_TYPE,
    };

    inline fn log_err(self: *const Self, err: Error, t: *const Token) Error {
        std.debug.print("{s}:{d}:{d}: ERROR: {}\n", .{
            self.file_path,
            t.loc.row + 1,
            t.loc.col + 1,
            err,
        });
        return err;
    }

    fn parse_inst(self: *Self, ty: InstType, operand_str: Token) !Inst {
        switch (operand_str.type) {
            .str, .label, .literal => return Inst.new(ty, InstValue.new([]const u8, operand_str.value)),
            .char => return Inst.new(ty, InstValue.new(u8, operand_str.value[0])),
            .int => {
                const int = std.fmt.parseInt(i64, operand_str.value, 10) catch |err| {
                    std.debug.print("Failed parsing int: {s}: {}\n", .{operand_str.value, err});
                    return self.log_err(Error.FAILED_TO_PARSE, &operand_str);
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
                const float = std.fmt.parseFloat(f64, operand_str.value) catch |err| {
                    std.debug.print("Failed parsing int: {s}: {}\n", .{operand_str.value, err});
                    return self.log_err(Error.FAILED_TO_PARSE, &operand_str);
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
        var lm = LabelMap.init(self.alloc);
        var im = InstMap.init(self.alloc);
        var program = Program.init(self.alloc);

        for (ts.items) |line| {
            var idx: u16 = 0;
            while (idx < line.len) : (idx += 1) {
                if (line[idx].type == .label) {
                    try program.append(Inst.new(.label, InstValue.new([]const u8, line[idx].value)));
                    try im.put(ip, line[idx].loc);
                    try lm.put(line[idx].value, ip);
                    ip += 1;
                    continue;
                }

                const tyo = InstType.try_from_str(line[idx].value);
                if (tyo == null)
                    return self.log_err(Error.UNDEFINED_SYMBOL, &line[idx]);

                const ty = tyo.?;
                if (!ty.arg_required()) {
                    try program.append(Inst.new(ty, inst.None));
                    try im.put(ip, line[idx].loc);
                    ip += 1;
                    continue;
                }

                if (idx + 1 > line.len) return self.log_err(Error.NO_OPERAND, &line[idx]);
                idx += 1;

                const operand = line[idx];
                if (std.mem.indexOf(Token.Type,
                                    ty.expected_types(),
                                    &[_]Token.Type{operand.type}) == null)
                {
                    return self.log_err(Error.INVALID_TYPE, &operand);
                }

                try program.append(try self.parse_inst(ty, operand));
                try im.put(ip, line[idx].loc);
                ip += 1;
            }
        }

        return Parsed {
            .program = program,
            .lm = lm,
            .im = im,
        };
    }
};
