const std      = @import("std");
const builtin  = @import("builtin");
const vm_mod   = @import("vm.zig");
const InstType = @import("inst.zig").InstType;

const panic   = vm_mod.panic;
const STR_CAP = vm_mod.Vm.STR_CAP;

const exit  = std.process.exit;
const print = std.debug.print;

pub const LinizedTokens = std.ArrayList([]const Token);

pub const Token = struct {
    type: Type,
    loc: Loc,
    str: []const u8,

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
            .str = value
        };
    }
};

const PpToken = struct {
    loc: Token.Loc,
    str: []const u8,
};

const Macro = union(enum) {
    single: []const PpToken,
    multi: struct {
        args: []const PpToken,
        body: []const []const Token,
    },
};

pub const Tokens = std.ArrayList([]const Token);
pub const MacroMap = std.StringHashMap(Macro);

pub const Lexer = struct {
    file_path: []const u8,
    include_path: ?[]const u8,
    macro_map: MacroMap,
    tokens: Tokens,

    alloc: std.mem.Allocator,

    const Self = @This();

    pub const PATH_CAP = 8 * 64;
    pub const CONTENT_CAP = 1024 * 1024;

    pub const DELIM = if (builtin.os.tag == .windows) '\\' else '/';

    pub const Error = error {
        INVALID_CHAR,
        UNEXPECTED_EOF,
        NO_CLOSING_QUOTE,
        UNDEFINED_SYMBOL,
        UNEXPECTED_SPACE_IN_MACRO_DEFINITION,
    };


    pub inline fn init(file_path: []const u8, alloc: std.mem.Allocator, include_path: ?[]const u8) Self {
        return .{
            .alloc = alloc,
            .file_path = file_path,
            .include_path = include_path,
            .macro_map = MacroMap.init(alloc),
            .tokens = Tokens.init(alloc)
        };
    }

    pub inline fn deinit(self: *Self) void {
        self.tokens.deinit();
        self.macro_map.deinit();
    }

    inline fn report_err(loc: Token.Loc, err: anyerror) anyerror {
        std.debug.print("{s}:{d}:{d}: ERROR: {}\n", .{
            loc.file_path,
            loc.row + 1,
            loc.col + 1,
            err,
        });
        return err;
    }

    fn get_include_content(self: *Self) !struct {[]const u8, []const u8} {
        return .{
            std.fs.cwd().readFileAlloc(self.alloc, self.file_path, CONTENT_CAP) catch |err| {
                if (self.include_path) |path| {
                    var path_buf_: [PATH_CAP]u8 = undefined;
                    const path_buf = try std.fmt.bufPrint(&path_buf_, "{s}{c}{s}", .{path, DELIM, self.file_path});
                    if (path_buf.len >= PATH_CAP)
                        return error.PATH_IS_TOO_LONG;

                    return .{
                        try read_file(path_buf, self.alloc),
                        path_buf
                    };
                } else panic("ERROR: Failed to read file: {s}: {}", .{self.file_path, err});
            }, self.include_path.?
        };
    }

    // Returns true if macro is multiline and false otherwise
    inline fn check_type_of_macro(line1: []const u8, line2: ?[]const u8) bool {
        if (std.mem.indexOf(u8, line1, "{") != null) return true;
        return if (line2) |some| std.mem.indexOf(u8, some, "{") != null else false;
    }

    fn handle_preprocessor(self: *Self, line: []const u8, row: *u32, words: []const ss, iter: anytype) !void {
        if (line.len < 2)
            return report_err(Token.Loc.new(row.*, 0, self.file_path), Error.UNEXPECTED_EOF);

        if (std.ascii.isWhitespace(line[1]))
            return report_err(Token.Loc.new(row.*, 1, self.file_path), Error.UNEXPECTED_SPACE_IN_MACRO_DEFINITION);

        if (line[1] == '"') {
            if (!std.mem.endsWith(u8, line, "\""))
                return report_err(Token.Loc.new(row.*, @intCast(line.len), self.file_path), Error.NO_CLOSING_QUOTE);

            var new_self = Self.init(line[2..line.len - 1], self.alloc, self.include_path);

            const ret = try new_self.get_include_content();

            const include_content = @field(ret, "0");
            const full_include_path = @field(ret, "1");
            new_self.file_path = full_include_path;

            try self.lex_file(include_content);


            // Append included macros into our existing `macro_map`
            var map_iter = new_self.macro_map.iterator();
            while (map_iter.next()) |e| {
                try self.macro_map.put(e.key_ptr.*, e.value_ptr.*);
            }

            for (new_self.tokens.items) |l| {
                try self.tokens.append(l);
            }
        } else {
            while (iter.peek()) |line_| {
                if (line_.len > 0) break;
                row.* += 1;
                _ = iter.next().?;
            }

            const name = words[0].str[1..words[0].str.len];
            var pp_tokens = try std.ArrayList(PpToken).initCapacity(self.alloc, words.len - 1);
            for (words[1..]) |t| {
                try pp_tokens.append(.{
                    .str = t.str,
                    .loc = Token.Loc.new(row.*, t.s, self.file_path)
                });
            }

            if (check_type_of_macro(line, iter.peek())) {
                var args = try std.ArrayList(PpToken).initCapacity(self.alloc, pp_tokens.items.len);
                for (pp_tokens.items) |pp| {
                    if (std.mem.eql(u8, pp.str, "{")) break;
                    if (std.mem.startsWith(u8, pp.str, "\"") or std.ascii.isDigit(pp.str[0])) {
                        std.debug.print("ERROR: arg's name: {s} can not be string literal or digit\n", .{pp.str});
                        return report_err(pp.loc, error.ARG_NAME_AS_DIGIT);
                    }

                    if (std.mem.indexOf(u8, pp.str, ",")) |_| {
                        const new_pp = PpToken {
                            .loc = pp.loc,
                            .str = std.mem.trim(u8, pp.str, ",")
                        };
                        try args.append(new_pp);
                    } else try args.append(pp);
                }

                while (iter.peek()) |some| {
                    if (some.len == 0 or some[0] == '{') {
                        row.* += 1;
                        _ = iter.next();
                    } else if (some.len > 0) {
                        break;
                    }
                }

                var body_str = std.ArrayList([]const u8).init(self.alloc);
                while (iter.peek()) |some| {
                    if (some.len == 0 or some[0] == '}') break;
                    row.* += 1;
                    try body_str.append(some);
                    _ = iter.next();
                }

                // Skip '}'
                _ = iter.next();
                row.* += 1;

                if (body_str.items.len == 0) {
                    try self.macro_map.put(name, .{
                        .multi = .{
                            .args = args.items,
                            .body = &[0][]const Token {},
                        }
                    });
                    return;
                }

                var body = std.ArrayList([]const Token).init(self.alloc);
                for (body_str.items) |l| {
                    var new_words = std.ArrayList(Token).init(self.alloc);
                    const splitted = try split_whitespace(l, self.alloc);
                    for (splitted) |w| {
                        const ty = try self.type_pp_token(w.str);
                        const pp = Token {
                            .type = ty,
                            .str = w.str,
                            .loc = Token.Loc.new(row.*, w.s, self.file_path)
                        };
                        try new_words.append(pp);
                    }
                    try body.append(new_words.items);
                }

                try self.macro_map.put(name, .{
                    .multi = .{
                        .args = args.items,
                        .body = body.items
                    }
                });
            } else {
                try self.macro_map.put(name, .{
                    .single = pp_tokens.items
                });
            }
        }
    }

    fn type_token(self: *Self, idx: *u64, row: u32, line_tokens: *std.ArrayList(Token), word: ss, words: []const ss) !Token.Type {
        if (std.mem.startsWith(u8, word.str, "\"")) {
            var strs = try std.ArrayList([]const u8).initCapacity(self.alloc, word.str.len);
            defer strs.deinit();
            while (true) : (idx.* += 1) {
                if (idx.* >= words.len)
                    return Error.NO_CLOSING_QUOTE;

                try strs.append(words[idx.*].str);
                if (std.mem.endsWith(u8, words[idx.*].str, "\"")) break;
            }

            var str = try std.mem.join(self.alloc, " ", strs.items);
            str = str[1..str.len - 1];
            const t = Token.new(.str, Token.Loc.new(row, word.s, self.file_path), str);
            try line_tokens.append(t);
        }

        if (std.mem.startsWith(u8, word.str, "'")) {
            if (!std.mem.endsWith(u8, word.str, "'"))
                return Error.INVALID_CHAR;

            if (word.str.len != 3)
                return Error.INVALID_CHAR;

            const t = Token.new(.char, Token.Loc.new(row, word.s, self.file_path), word.str[1..2]);
            try line_tokens.append(t);
            idx.* += 1;
        }

        if (std.mem.startsWith(u8, word.str, "-")) {
            if (word.str.len < 2)
                return error.UNEXPECTED_EOF;

            if (!std.ascii.isDigit(word.str[1]))
                return error.INVALID_LITERAL;

            if (std.mem.indexOf(u8, word.str[1..word.str.len], ".")) |_| {
                return .float;
            } else
                return .int;
        }

        return if (std.ascii.isDigit(word.str[0])) {
            return if (std.mem.indexOf(u8, word.str, ".")) |_|
                .float
            else
                .int;
        } else .literal;
    }

    fn type_pp_token(_: *Self, str: []const u8) !Token.Type {
        if (std.mem.startsWith(u8, str, "\"")) {
            return .str;
        } else if (std.mem.startsWith(u8, str, "'")) {
            return .char;
        } else if (std.mem.startsWith(u8, str, "-")) {
            if (str.len < 2)
                return error.UNEXPECTED_EOF;

            if (!std.ascii.isDigit(str[1]))
                return error.INVALID_LITERAL;

            if (std.mem.indexOf(u8, str[1..str.len], ".")) |_| {
                return .float;
            } else
                return .int;
        } else if (std.ascii.isDigit(str[0])) {
            if (std.mem.indexOf(u8, str, ".")) |_|
                return .float
            else
                return .int;
        } else
            return .literal;
    }

    fn handle_macro(self: *Self, macro: Macro, row: u32, idx: *usize, line_tokens: *std.ArrayList(Token), words: []const ss) !void {
        const word = words[idx.*];
        switch (macro) {
            .multi => |pp| {
                if (pp.args.len == 0) {
                    if (words.len > 1) {
                        print("ERROR: unexpected arguments when macro: {s} does not accept any\n", .{word.str});
                        return report_err(Token.Loc.new(row, word.s, self.file_path), error.UNEXPECTED_ARGUMENTS);
                    }

                    try self.tokens.appendSlice(pp.body);
                    return;
                }

                idx.* += 1;

                if (words.len - idx.* < pp.args.len) {
                    print("ERROR: too few arguments for macro `{s}`, expected: {d}\n", .{word.str, pp.args.len});
                    return report_err(.{
                        .row = row,
                        .col = word.s,
                        .file_path = self.file_path,
                    }, error.TOO_FEW_ARGUMENTS);
                }

                var count: usize = 0;
                var args_map = std.StringHashMap(ss).init(self.alloc);
                while (idx.* < words.len) : (idx.* += 1) {
                    const str = words[idx.*].str;

                    // Handle string literals
                    if (std.mem.startsWith(u8, str, "\"")) {
                        var strs = try std.ArrayList([]const u8).initCapacity(self.alloc, str.len);
                        defer strs.deinit();

                        while (true) : (idx.* += 1) {
                            if (idx.* >= words.len)
                                return Error.NO_CLOSING_QUOTE;

                            try strs.append(words[idx.*].str);
                            if (std.mem.endsWith(u8, words[idx.*].str, "\"")) break;
                        }

                        const wss = .{
                            .s = word.s,
                            .str = try std.mem.join(self.alloc, " ", strs.items),
                        };

                        try args_map.put(pp.args[count].str, wss);
                        count += 1;
                        continue;
                    }

                    if (count >= pp.args.len or args_map.unmanaged.size > pp.args.len) {
                        print("ERROR: too many arguments for macro `{s}`, expected: {d}\n", .{word.str, pp.args.len});
                        return report_err(.{
                            .row = row,
                            .col = word.s,
                            .file_path = self.file_path,
                        }, error.TOO_MANY_ARGUMENTS);
                    }

                    var wss: ss = undefined;
                    if (std.mem.indexOf(u8, str, ",") != null or std.mem.indexOf(u8, str, "\"") != null) {
                        wss = .{
                            .s = words[idx.*].s,
                            .str = std.mem.trim(u8, str, ",")
                        };
                    } else wss = words[idx.*];

                    try args_map.put(pp.args[count].str, wss);
                    count += 1;
                }

                for (pp.body) |pp_line| {
                    var expansion = try std.ArrayList(Token).initCapacity(self.alloc, pp_line.len);
                    for (pp_line) |pp_t| {
                        if (args_map.get(pp_t.str)) |v| {
                            var ty: Token.Type = undefined;
                            if (std.mem.startsWith(u8, v.str, "\"")) {
                                ty = .str;
                            } else if (std.mem.startsWith(u8, v.str, "'")) {
                                ty = .char;
                            } else if (std.mem.startsWith(u8, v.str, "-")) {
                                ty = .int;
                            } else if (std.ascii.isDigit(v.str[0])) {
                                if (std.mem.indexOf(u8, v.str, ".")) |_| {
                                    ty = .float;
                                } else {
                                    ty = .int;
                                }
                            } else {
                                ty = .literal;
                            }

                            const t = Token.new(ty, .{
                                .row = row,
                                .col = v.s,
                                .file_path = self.file_path,
                            }, std.mem.trim(u8, v.str, "\""));
                            try expansion.append(t);
                        } else {
                            try expansion.append(pp_t);
                        }
                    }
                    try self.tokens.append(expansion.items);
                }
            },
            .single => |pp_ts| {
                var pp_idx: usize = 0;
                while (pp_idx < pp_ts.len) : (pp_idx += 1) {
                    const loc = pp_ts[pp_idx].loc;
                    const str = pp_ts[pp_idx].str;
                    const ty = try self.type_pp_token(str);
                    if (ty == .str) {
                        try line_tokens.append(Token.new(ty, loc, str[1..str.len - 1]));
                    } else {
                        try line_tokens.append(Token.new(ty, loc, str));
                    }
                }
            }
        }
    }

    pub fn lex_file(self: *Self, content: []const u8) anyerror!void {
        var row: u32 = 0;
        var iter = std.mem.split(u8, content, "\n");
        while (iter.next()) |line| : (row += 1) {
            if (line.len == 0) continue;

            const words = try split_whitespace(line, self.alloc);
            var line_tokens = try std.ArrayList(Token).initCapacity(self.alloc, words.len);
            defer self.tokens.append(line_tokens.items) catch exit(1);

            // Found a preprocessor thingy
            if (std.mem.startsWith(u8, line, "#")) {
                try self.handle_preprocessor(line, &row, words, &iter);
                continue;
            }

            // Found a label
            if (std.ascii.isASCII(line[0]) and std.mem.endsWith(u8, line, ":")) {
                if (words.len > 1)
                    return report_err(Token.Loc.new(row, words[0].s, self.file_path), Error.UNDEFINED_SYMBOL);

                const label = words[0].str[0..words[0].str.len - 1];
                const start = words[0].s;

                const t = Token.new(.label, .{
                    .row = row, .col = start,
                    .file_path = self.file_path,
                }, label);
                try line_tokens.append(t);
                continue;
            }

            var idx: usize = 0;
            while (idx < words.len) : (idx += 1) {
                const word = words[idx];
                if (std.mem.startsWith(u8, word.str, "@")) {
                    if (word.str.len == 1)
                        return report_err(Token.Loc.new(row, word.s, self.file_path), error.UNEXPECTED_EOF);

                    if (self.macro_map.get(std.mem.trim(u8, word.str[1..word.str.len], " "))) |macro| {
                        try self.handle_macro(macro, row, &idx, &line_tokens, words);
                        continue;
                    } else {
                        print("ERROR: undefined macro: {s}\n", .{word.str});
                        return report_err(Token.Loc.new(row, word.s, self.file_path), error.UNDEFINED_MACRO);
                    }
                }

                const ty = self.type_token(&idx, row, &line_tokens, word, words) catch |err| {
                    return report_err(Token.Loc.new(row, word.s, self.file_path), err);
                };
                const t = Token.new(ty, Token.Loc.new(row, word.s, self.file_path), word.str);
                try line_tokens.append(t);
            }
        }
    }

    pub inline fn read_file(file_path: []const u8, alloc: std.mem.Allocator) ![]const u8 {
        return std.fs.cwd().readFileAlloc(alloc, file_path, CONTENT_CAP) catch |err| {
            panic("ERROR: Failed to read file: {s}: {}", .{file_path, err});
        };
    }

    const ss = struct {
        s: u32,
        str: []const u8,
    };

    fn split_whitespace(input: []const u8, alloc: std.mem.Allocator) ![]const ss {
        var s: u32 = 0;
        var e: u32 = 0;
        var ret = std.ArrayList(ss).init(alloc);
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
