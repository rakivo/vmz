const std    = @import("std");
const inst   = @import("inst.zig");
const lexer  = @import("lexer.zig");
const NaNBox = @import("NaNBox.zig").NaNBox;

const Inst = inst.Inst;
const InstType = inst.InstType;
const InstValue = inst.InstValue;

const Token = lexer.Token;
const LinizedTokens = lexer.LinizedTokens;

pub const Parser = struct {
    fn parse_inst(ty: InstType, operand_str: Token) !Inst {
        switch (operand_str.type) {
            .str, .literal => return Inst.new(ty, InstValue.new([]const u8, operand_str.value)),
            .int => {
                const int = std.fmt.parseInt(i64, operand_str.value, 10) catch |err| {
                    std.debug.print("Failed parsing int: {s}: {}\n", .{operand_str.value, err});
                    return error.FAILED_TO_PARSE;
                };
                if (ty == .push) {
                    return Inst.new(ty, InstValue.new(NaNBox, NaNBox.from(i64, @intCast(int))));
                } else {
                    return Inst.new(ty, InstValue.new(i64, int));
                }
            },
            .float => {
                const float = std.fmt.parseFloat(f64, operand_str.value) catch |err| {
                    std.debug.print("Failed parsing int: {s}: {}\n", .{operand_str.value, err});
                    return error.FAILED_TO_PARSE;
                };
                if (ty == .push) {
                    return Inst.new(ty, InstValue.new(NaNBox, NaNBox.from(f64, float)));
                } else {
                    return Inst.new(ty, InstValue.new(f64, float));
                }
            }
        }
    }

    pub fn parse(ts: *LinizedTokens, alloc: std.mem.Allocator) !std.ArrayList(Inst) {
        var program = std.ArrayList(Inst).init(alloc);
        for (ts.items) |line| {
            var idx: usize = 0;
            while (idx < line.len) : (idx += 1) {
                const t = line[idx];
                const tyo = InstType.try_from_str(t.value);
                if (tyo) |ty| {
                    if (!ty.arg_required()) {
                        try program.append(Inst.new(ty, inst.None));
                        continue;
                    }

                    if (idx + 1 > line.len) return error.NO_OPERAND;
                    idx += 1;

                    const operand_str = line[idx];
                    const expected_operand_types = ty.expected_type();
                    for (expected_operand_types) |ty_|
                        if (ty_ != operand_str.type) return error.INVALID_TYPE;

                    try program.append(try parse_inst(ty, operand_str));
                }
            }
        }

        return program;
    }
};
