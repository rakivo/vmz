const std     = @import("std");
const builtin = @import("builtin");
const STR_CAP = @import("vm.zig").Vm.STR_CAP;

const exit  = std.process.exit;
const print = std.debug.print;

pub const LinizedTokens = std.ArrayList([]const Token);

pub const Token = struct {
    type: Type,
    loc: Loc,
    value: []const u8,

    const Self = @This();

    pub const Loc = struct {
        row: u32, col: u32,
        file_path: []const u8,

        pub fn new(row: u32, col: u32, file_path: []const u8) Loc {
            return .{.row = row, .col = col, .file_path = file_path};
        }
    };

    pub const Type = enum {
        str, int, char, label, float, literal
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
    include_path: ?[]const u8,

    alloc: std.mem.Allocator,
    tokens: std.ArrayList([]const Token),

    const Self = @This();

    pub const CONTENT_CAP = 1024 * 1024;

    pub const Error = error {
        INVALID_CHAR,
        UNEXPECTED_EOF,
        NO_CLOSING_QUOTE,
        UNDEFINED_SYMBOL,
    };

    inline fn report_err(loc: Token.Loc, err: anyerror) anyerror {
        std.debug.print("{s}:{d}:{d}: ERROR: {}\n", .{
            loc.file_path,
            loc.row + 1,
            loc.col + 1,
            err,
        });
        return err;
    }

    fn _get_include_content(file_path: []const u8, alloc: std.mem.Allocator, include_path: ?[]const u8) !struct {[]const u8, []const u8} {
        return .{
            std.fs.cwd().readFileAlloc(alloc, file_path, CONTENT_CAP) catch |err| {
                if (include_path) |path| {
                    // format these constants out of here.
                    const PATH_CAP = 128;
                    const DELIM = if (builtin.os.tag == .windows) '\\' else '/';

                    var path_buf_: [PATH_CAP]u8 = undefined;
                    const path_buf = try std.fmt.bufPrint(&path_buf_, "{s}{c}{s}", .{path, DELIM, file_path});
                    if (path_buf.len >= PATH_CAP)
                        return error.PATH_IS_TOO_LONG;

                    return .{
                        try read_file(path_buf, alloc),
                        path_buf
                    };
                } else {
                    print("ERROR: Failed to read file: {s}: {}\n", .{file_path, err});
                    exit(1);
                }
            }, include_path.?
        };
    }

    fn lex_file(file_path: []const u8, content: []const u8, alloc: std.mem.Allocator, include_path: ?[]const u8) !LinizedTokens {
        var row: u32 = 0;
        var iter = std.mem.split(u8, content, "\n");
        var tokens = std.ArrayList([]const Token).init(alloc);
        while (iter.next()) |line| : (row += 1) {
            if (line.len == 0) continue;

            const words = try split_whitespace(line, alloc);
            var line_tokens = try std.ArrayList(Token).initCapacity(alloc, words.len);
            defer tokens.append(line_tokens.items) catch exit(1);

            // Found include statement
            if (std.mem.startsWith(u8, line, "#")) {
                if (line.len < 2)
                    return report_err(Token.Loc.new(row, 0, file_path), Error.UNEXPECTED_EOF);

                // TODO: clean this out.
                if (line[1] == '"') {
                    if (!std.mem.endsWith(u8, line, "\""))
                        return report_err(Token.Loc.new(row, @intCast(line.len), file_path), Error.NO_CLOSING_QUOTE);

                    const ret = try _get_include_content(line[2..line.len - 1], alloc, include_path);
                    const include_content = @field(ret, "0");
                    const full_include_path = @field(ret, "1");
                    const include_tokens = try lex_file(full_include_path, include_content, alloc, include_path);
                    for (include_tokens.items) |l|
                        try tokens.append(l);
                }
                continue;
            }

            // Found a label
            if (std.ascii.isASCII(line[0]) and std.mem.endsWith(u8, line, ":")) {
                if (words.len > 1)
                    return report_err(Token.Loc.new(row, words[0].s, file_path), Error.UNDEFINED_SYMBOL);

                const label = words[0].str[0..words[0].str.len - 1];
                const start = words[0].s;

                const t = Token.new(.label, .{
                    .row = row, .col = start,
                    .file_path = file_path,
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
                            .row = row, .col = word.s,
                            .file_path = file_path,
                        }, str);
                        try line_tokens.append(t);
                        continue;
                    }

                    if (std.mem.startsWith(u8, word.str, "'")) {
                        if (!std.mem.endsWith(u8, word.str, "'"))
                            break :blk Error.INVALID_CHAR;

                        if (word.str.len != 3)
                            break :blk Error.INVALID_CHAR;

                        const t = Token.new(.char, .{
                            .row = row, .col = word.s,
                            .file_path = file_path
                        }, word.str[1..2]);
                        try line_tokens.append(t);
                        idx += 1;
                        continue;
                    }

                    if (std.mem.startsWith(u8, word.str, "-")) {
                        if (word.str.len < 2)
                            return error.UNEXPECTED_EOF;

                        if (!std.ascii.isDigit(word.str[1]))
                            return error.INVALID_LITERAL;

                        if (std.mem.indexOf(u8, word.str[1..word.str.len], ".")) |_| {
                            break :blk .float;
                        } else
                            break :blk .int;

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
                    return report_err(Token.Loc.new(row, word.s, file_path), err);
                }, Token.Loc.new(row, word.s, file_path), word.str);

                try line_tokens.append(t);
            }
        }

        return tokens;
    }

    pub inline fn read_file(file_path: []const u8, alloc: std.mem.Allocator) ![]const u8 {
        return std.fs.cwd().readFileAlloc(alloc, file_path, CONTENT_CAP) catch |err| {
            print("ERROR: Failed to read file: {s}: {}\n", .{file_path, err});
            exit(1);
        };
    }

    pub fn init(file_path: []const u8, alloc: std.mem.Allocator, include_path: ?[]const u8) !Self {
        const content = try read_file(file_path, alloc);
        return .{
            .alloc = alloc,
            .file_path = file_path,
            .include_path = include_path,
            .tokens = try lex_file(file_path, content, alloc, include_path)
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
