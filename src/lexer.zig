const std = @import("std");
const flag = @import("flag.zig");

const Flag = flag.Flag;
const Parser = flag.Parser;

const print = std.debug.print;

const src_flag = Flag([]const u8, "-p", "--path", .{
    .help = "path to src file",
    .mandatory = true,
}).new();

pub const Token = struct {
    type: Type,
    info: Info,
    value: []const u8,

    const Self = @This();

    pub const Info = packed struct { row: u32, col: u32 };
    pub const Type = enum {
        str, int, float, literal
    };

    pub inline fn new(typ: Type, info: Info, value: []const u8) Self {
        return .{
            .type = typ,
            .info = info,
            .value = value
        };
    }
};

pub const Lexer = struct {
    file_path: []const u8,
    arena: *std.heap.ArenaAllocator,
    tokens: std.ArrayList([]const Token),

    const Self = @This();
    const CONTENT_CAP = 1024 * 1024;

    fn lex_file(content: []const u8, arena: anytype) !std.ArrayList([]const Token) {
        var row: u32 = 0;
        var iter = std.mem.split(u8, content, "\n");
        var tokens = std.ArrayList([]const Token).init(arena.allocator());
        while (iter.next()) |line| : (row += 1) {
            const words = try split_whitespace(line);
            var line_tokens = try std.ArrayList(Token).initCapacity(arena.allocator(), words.len);
            defer tokens.append(line_tokens.items) catch unreachable;
            for (words) |word| {
                const tt: LexingError!Token.Type = blk: {
                    if (std.mem.startsWith(u8, word.str, "\"")) {
                        if (std.mem.endsWith(u8, word.str, "\"")) break :blk .str
                        else break :blk LexingError.NO_CLOSING_QUOTE;
                    }

                    if (std.ascii.isDigit(word.str[0])) {
                        if (std.mem.indexOf(u8, word.str, ".")) |_|
                            break :blk .float
                        else
                            break :blk .int;
                    } else break :blk .literal;
                };

                const t = Token.new(try tt, .{
                    .row = row, .col = word.s
                }, word.str);

                try line_tokens.append(t);
            }
        }

        return tokens;
    }

    pub fn init(flag_parser: *Parser, arena: *std.heap.ArenaAllocator) !Self {
        const file_path = flag_parser.parse(src_flag).?;
        const content = std.fs.cwd().readFileAlloc(arena.allocator(), file_path, CONTENT_CAP) catch |err| {
            print("ERROR: Failed to read file: {s}: {}\n", .{file_path, err});
            unreachable;
        };
        return .{
            .arena = arena,
            .file_path = file_path,
            .tokens = try lex_file(content, arena)
        };
    }

    pub inline fn deinit(self: Self) void {
        self.arena.allocator().free(self.tokens.items);
    }

    const LexingError = error {
        NO_CLOSING_QUOTE,
    };

    const ss = struct {
        s: u32,
        str: []const u8,
    };

    fn split_whitespace(input: []const u8) ![]const ss {
        var ret = std.ArrayList(ss).init(std.heap.page_allocator);

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
