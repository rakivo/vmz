const std     = @import("std");
const STR_CAP = @import("vm.zig").Vm.STR_CAP;

const exit  = std.process.exit;
const print = std.debug.print;

pub const LinizedTokens = std.ArrayList([]const Token);

pub const Token = struct {
    type: Type,
    loc: Loc,
    value: []const u8,

    const Self = @This();

    pub const Loc = struct { row: u32, col: u32 };
    pub const Type = enum {
        str, int, label, float, literal
    };

    pub inline fn new(typ: Type, loc: Loc, value: []const u8) Self {
        return .{
            .type = typ,
            .loc = loc,
            .value = value
        };
    }
};

pub const Lexer = struct {
    file_path: []const u8,
    alloc: std.mem.Allocator,
    tokens: std.ArrayList([]const Token),

    const Self = @This();
    const CONTENT_CAP = 1024 * 1024;

    pub const Error = error {
        NO_CLOSING_QUOTE,
        UNDEFINED_SYMBOL,
    };

    fn lex_file(file_path: []const u8, content: []const u8, alloc: std.mem.Allocator) !LinizedTokens {
        var row: u32 = 0;
        var iter = std.mem.split(u8, content, "\n");
        var tokens = std.ArrayList([]const Token).init(alloc);
        while (iter.next()) |line| : (row += 1) {
            if (line.len == 0) continue;

            const words = try split_whitespace(line, alloc);
            var line_tokens = try std.ArrayList(Token).initCapacity(alloc, words.len);
            defer tokens.append(line_tokens.items) catch exit(1);

            // Found a label
            if (std.ascii.isASCII(line[0]) and std.mem.endsWith(u8, line, ":")) {
                if (words.len > 1) {
                    std.debug.print("{s}:{d}:{d}: ERROR: {}\n", .{
                        file_path,
                        row + 1,
                        words[0].s + 1,
                        Error.UNDEFINED_SYMBOL,
                    });
                    return Error.UNDEFINED_SYMBOL;
                }

                const label = words[0].str[0..words[0].str.len - 1];
                const start = words[0].s;

                const t = Token.new(.label, .{
                    .row = row, .col = start
                }, label);

                try line_tokens.append(t);
                continue;
            }

            var idx: usize = 0;
            while (idx < words.len) : (idx += 1) {
                const word = words[idx];
                const tt: Error!Token.Type = blk: {
                    if (std.mem.startsWith(u8, word.str, "\"")) {
                        var strs = try std.ArrayList([]const u8).initCapacity(alloc, word.str.len);
                        defer strs.deinit();
                        while (true) : (idx += 1) {
                            if (idx >= words.len)
                                break :blk Error.NO_CLOSING_QUOTE;

                            try strs.append(words[idx].str);
                            if (std.mem.endsWith(u8, words[idx].str, "\"")) break;
                        }

                        var str = try std.mem.join(alloc, " ", strs.items);
                        str = str[1..str.len - 1];
                        const t = Token.new(.str, .{
                            .row = row, .col = word.s
                        }, str);
                        try line_tokens.append(t);
                        continue;
                    }

                    if (std.ascii.isDigit(word.str[0])) {
                        if (std.mem.indexOf(u8, word.str, ".")) |_|
                            break :blk .float
                        else
                            break :blk .int;
                    } else
                        break :blk .literal;
                };

                const t = Token.new(tt catch |err| {
                    std.debug.print("{s}:{d}:{d}: ERROR: {}\n", .{
                        file_path,
                        row + 1,
                        word.s + 1,
                        err
                    });
                    return err;
                }, .{
                    .row = row, .col = word.s
                }, word.str);

                try line_tokens.append(t);
            }
        }

        return tokens;
    }

    pub fn init(file_path: []const u8, alloc: std.mem.Allocator) !Self {
        const content = std.fs.cwd().readFileAlloc(alloc, file_path, CONTENT_CAP) catch |err| {
            print("ERROR: Failed to read file: {s}: {}\n", .{file_path, err});
            exit(1);
        };
        return .{
            .alloc = alloc,
            .file_path = file_path,
            .tokens = try lex_file(file_path, content, alloc)
        };
    }

    pub inline fn deinit(self: Self) void {
        self.alloc.free(self.tokens.items);
    }

    const ss = struct {
        s: u32,
        str: []const u8,
    };

    fn split_whitespace(input: []const u8, alloc: std.mem.Allocator) ![]const ss {
        var ret = std.ArrayList(ss).init(alloc);

        var s: u32 = 0;
        var e: u32 = 0;
        while (e < input.len) : (e += 1)
            if (std.ascii.isWhitespace(input[e])) {
                if (s != e)
                    try ret.append(.{
                        .s = s, .str = input[s..e]
                    });

                s = e + 1;
            };

        if (s != e)
            try ret.append(.{
                .s = s, .str = input[s..e]
            });

        return ret.items;
    }
};
