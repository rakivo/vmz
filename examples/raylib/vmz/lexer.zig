const std      = @import("std");
const builtin  = @import("builtin");
const vm_mod   = @import("vm.zig");
const InstType = @import("inst.zig").InstType;

const panic   = vm_mod.panic;
const STR_CAP = vm_mod.Vm.STR_CAP;

const exit  = std.process.exit;
const print = std.debug.print;

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
        args: Tokens,
        body: []const Tokens,
    },
};

pub const Tokens = []const Token;
pub const MacroMap = std.StringHashMap(Macro);
pub const LinizedTokens = std.ArrayList(Tokens);
pub const TokensArrayList = std.ArrayList(Tokens);

pub const Lexer = struct {
    macro_map: MacroMap,
    tokens: TokensArrayList,
    alloc: std.mem.Allocator,

    file_path: []const u8,
    include_path: ?[]const u8,

    const Self = @This();

    pub const PATH_CAP = 8 * 64;
    pub const CONTENT_CAP = 1024 * 1024;

    pub const PP_SYMBOL = "#";
    pub const MACRO_SYMBOL = "@";
    pub const COMMENT_SYMBOL = ";";
    pub const ERROR_TEXT = "ERROR";
    pub const DELIM = if (builtin.os.tag == .windows) '\\' else '/';

    pub inline fn init(file_path: []const u8, alloc: std.mem.Allocator, include_path: ?[]const u8) Self {
        return .{
            .alloc = alloc,
            .file_path = file_path,
            .include_path = include_path,
            .macro_map = MacroMap.init(alloc),
            .tokens = TokensArrayList.init(alloc)
        };
    }

    pub inline fn deinit(self: *Self) void {
        self.tokens.deinit();
        self.macro_map.deinit();
    }

    pub inline fn report_err(loc: Token.Loc, err: anyerror) anyerror {
        std.debug.print("{s}:{d}:{d}: " ++ ERROR_TEXT ++ ": {}\n", .{
            loc.file_path,
            loc.row + 1,
            loc.col + 1,
            err,
        });
        unreachable;
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
        return if (std.mem.indexOf(u8, line1, "{") != null) return true
        else if (line2) |some| {
            return if (std.mem.startsWith(u8, some, PP_SYMBOL))
                false
            else
                std.mem.indexOf(u8, some, "{") != null;
        } else
            false;
    }

    fn handle_preprocessor(self: *Self, row: *u32, line: []const u8, words: []const Ss, iter: anytype) !void {
        if (line.len < 2)
            return report_err(Token.Loc.new(row.*, 0, self.file_path), error.UNEXPECTED_EOF);

        if (std.ascii.isWhitespace(line[1]))
            return report_err(Token.Loc.new(row.*, 1, self.file_path), error.UNEXPECTED_SPACE_IN_MACRO_DEFINITION);

        if (line[1] == '"') {
            if (!std.mem.endsWith(u8, line, "\""))
                return report_err(Token.Loc.new(row.*, @intCast(line.len), self.file_path), error.NO_CLOSING_QUOTE);

            var new_self = Self.init(line[2..line.len - 1], self.alloc, self.include_path);

            const ret = try new_self.get_include_content();

            const include_content = @field(ret, "0");
            const full_include_path = @field(ret, "1");
            new_self.file_path = full_include_path;

            try self.lex_file(include_content);

            // Append included macros into our existing `macro_map`
            var map_iter = new_self.macro_map.iterator();
            while (map_iter.next()) |e|
                try self.macro_map.put(e.key_ptr.*, e.value_ptr.*);

            for (new_self.tokens.items) |l|
                try self.tokens.append(l);

        } else {
            while (iter.peek()) |line_| {
                if (line_.len > 0) break;
                row.* += 1;
                _ = iter.next().?;
            }

            // Collect tokens from current line.
            const name = words[0].str[1..];
            var pp_tokens = try std.ArrayList(PpToken).initCapacity(self.alloc, words.len - 1);
            for (words[1..]) |t| {
                try pp_tokens.append(.{
                    .str = t.str,
                    .loc = Token.Loc.new(row.*, t.s, self.file_path)
                });
            }

            if (check_type_of_macro(line, iter.peek())) {
                var args = try std.ArrayList(Token).initCapacity(self.alloc, pp_tokens.items.len);

                // Collect tokens after name of the macro and before `{`
                var idx_: usize = 0;
                while (idx_ < pp_tokens.items.len) : (idx_ += 1) {
                    const pp = pp_tokens.items[idx_];

                    if (std.mem.eql(u8, pp.str, "{")) break;
                    if (!std.ascii.isAlphabetic(pp.str[0])) {
                        std.debug.print("ERROR: arg's name: {s} can must be alphabetic\n", .{pp.str});
                        return report_err(pp.loc, error.ARG_NAME_AS_STRING_DIGIT_LITERAL);
                    }

                    const new_pp = Token.new(type_token_light(pp.str), pp.loc, std.mem.trim(u8, pp.str, ","));
                    try args.append(new_pp);
                }

                // Skip until '{'
                while (iter.peek()) |some| {
                    if (some.len == 0 or some[0] == '{') {
                        row.* += 1;
                        _ = iter.next();
                    } else if (some.len > 0) break;
                }

                // Collect tokens in between of curly braces
                var body_str = std.ArrayList([]const u8).init(self.alloc);
                while (iter.peek()) |some| {
                    if (some.len == 0 or some[0] == '}') break;
                    try body_str.append(some);
                    _ = iter.next();
                }

                // Skip '}'
                _ = iter.next();
                row.* += 1;

                // Body is empty
                if (body_str.items.len == 0) {
                    try self.macro_map.put(name, .{
                        .multi = .{
                            .args = args.items,
                            .body = &[0][]const Token {},
                        }
                    });

                    return;
                }

                var body = TokensArrayList.init(self.alloc);
                for (body_str.items) |l| {
                    var idx: usize = 0;
                    var new_words = std.ArrayList(Token).init(self.alloc);
                    const splitted = try split_whitespace(l, self.alloc);
                    while (idx < splitted.len) : (idx += 1) {
                        const w = splitted[idx];
                        const pp = Token {
                            .type = try self.type_pp_token(w.str),
                            .str = w.str,
                            .loc = Token.Loc.new(row.*, w.s, self.file_path)
                        };
                        try new_words.append(pp);
                    }

                    row.* += 1;
                    try body.append(new_words.items);
                }

                try self.macro_map.put(name, .{
                    .multi = .{
                        .args = args.items,
                        .body = body.items
                    }
                });
            } else {
                var idx: usize = 0;
                var new_pps = try std.ArrayList(PpToken).initCapacity(self.alloc, pp_tokens.items.len);
                while (idx < pp_tokens.items.len) : (idx += 1) {
                    const w = pp_tokens.items[idx];
                    const loc = Token.Loc.new(w.loc.row -% 1, w.loc.col, w.loc.file_path);

                    // Found another macro in this macro.
                    if (std.mem.startsWith(u8, w.str, MACRO_SYMBOL)) {
                        if (w.str.len == 1)
                            return report_err(w.loc, error.UNEXPECTED_EOF);

                        if (self.macro_map.get(std.mem.trim(u8, w.str[1..w.str.len], " "))) |macro| {
                            switch (macro) {
                                .single => |ts| try new_pps.appendSlice(ts),
                                .multi => |_| panic("TODO: Unimplemented", .{})
                            }
                        } else {
                            print("ERROR: undefined macro: {s}\n", .{w.str});
                            return report_err(loc, error.UNDEFINED_MACRO);
                        }

                        continue;
                    // Handle string literals.
                    } else if (std.mem.startsWith(u8, w.str, "\"")) {
                        var strs = try std.ArrayList([]const u8).initCapacity(self.alloc, w.str.len);
                        defer strs.deinit();
                        while (true) : (idx += 1) {
                            if (idx >= pp_tokens.items.len)
                                return error.NO_CLOSING_QUOTE;

                            try strs.append(pp_tokens.items[idx].str);
                            if (std.mem.endsWith(u8, pp_tokens.items[idx].str, "\"")) break;
                        }

                        const str = try std.mem.join(self.alloc, " ", strs.items);
                        const t = PpToken {
                            .loc = w.loc,
                            .str = str,
                        };
                        try new_pps.append(t);
                    } else try new_pps.append(w);
                }

                try self.macro_map.put(name, .{.single = new_pps.items});
            }
        }
    }

    fn type_token_light(str: []const u8) Token.Type {
        return if (std.mem.startsWith(u8, str, "\""))                     .str
        else if (std.mem.startsWith(u8, str, "'"))                        .char
        else if (std.mem.startsWith(u8, str, "-"))                        .int
        else if (std.ascii.isDigit(str[0])) {
            return if (std.mem.indexOf(u8, str, ".") != null)
                                                                          .float
            else
                                                                          .int;
        } else                                                            .literal;
    }

    fn type_pp_token(_: *Self, str: []const u8) !Token.Type {
        return if (std.mem.startsWith(u8, str, "\""))                     .str
        else if (std.mem.startsWith(u8, str, "'"))
                                                                          .char
        else if (std.mem.startsWith(u8, str, "-")) {
            if (str.len < 2)
                return error.UNEXPECTED_EOF;

            if (!std.ascii.isDigit(str[1]))
                return error.INVALID_LITERAL;

            return if (std.mem.indexOf(u8, str[1..str.len], ".") != null)
                                                                          .float
            else
                                                                          .int;
        } else if (std.ascii.isDigit(str[0])) {
            return if (std.mem.indexOf(u8, str, ".") != null)
                                                                          .float
            else
                                                                          .int;
        } else                                                            .literal;
    }

    fn handle_macro(self: *Self, macro: Macro, row: u32, idx: *usize,
                    line_tokens: *std.ArrayList(Token), words: []const Ss,
                    nargs_map: ?std.StringHashMap(Ss)) !void
    {
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

                // Skip name
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
                var args_map = std.StringHashMap(Ss).init(self.alloc);
                while (idx.* < words.len) : (idx.* += 1) {
                    const str = words[idx.*].str;

                    if (std.mem.eql(u8, str, "{")) break;

                    // Handle string literals
                    if (std.mem.startsWith(u8, str, "\"")) {
                        defer count += 1;

                        var strs = try std.ArrayList([]const u8).initCapacity(self.alloc, str.len);
                        defer strs.deinit();

                        while (true) : (idx.* += 1) {
                            if (idx.* >= words.len)
                                return error.NO_CLOSING_QUOTE;

                            const str_ = words[idx.*].str;
                            try strs.append(str_);
                            if (std.mem.endsWith(u8, str_, "\"")) break;
                        }

                        const wss = .{
                            .s = word.s,
                            .str = try std.mem.join(self.alloc, " ", strs.items),
                        };

                        try args_map.put(pp.args[count].str, wss);
                        continue;
                    }

                    if (nargs_map) |map| {
                        if (map.get(str)) |some| {
                            try args_map.put(pp.args[count].str, some);
                            continue;
                        }
                    }

                    const loc = Token.Loc.new(row, word.s, self.file_path);
                    if (count >= pp.args.len or args_map.unmanaged.size > pp.args.len) {
                        print("ERROR: too many arguments for macro `{s}`, expected: {d}\n", .{word.str, pp.args.len});
                        const loc_ = Token.Loc {
                            .row = row - 1,
                            .col = word.s,
                            .file_path = self.file_path
                        };
                        return report_err(loc_, error.TOO_MANY_ARGUMENTS);
                    }

                    const wss = if (std.mem.indexOf(u8, str, ",") != null or
                                    std.mem.indexOf(u8, str, "\"") != null)
                    Ss {
                        .s = words[idx.*].s,
                        .str = std.mem.trim(u8, str, ",")
                    } else words[idx.*];

                    if (std.mem.startsWith(u8, wss.str, MACRO_SYMBOL)) {
                        if (wss.str.len == 1)
                            return report_err(loc, error.UNEXPECTED_EOF);

                        if (self.macro_map.get(std.mem.trim(u8, wss.str[1..wss.str.len], " "))) |new_macro| {
                            var macro_tokens = std.ArrayList(Token).init(self.alloc);
                            try self.handle_macro(new_macro, row, idx, &macro_tokens, words, args_map);

                            const wss_ = if (macro_tokens.items.len > 0) Ss {
                                .s = macro_tokens.items[0].loc.col,
                                .str = macro_tokens.items[0].str
                            } else Ss {
                                .s = wss.s,
                                .str = ""
                            };

                            try args_map.put(pp.args[count].str, wss_);
                            continue;
                        } else {
                            print("ERROR: undefined macro: {s}\n", .{wss.str});
                            return report_err(loc, error.UNDEFINED_MACRO);
                        }
                    }

                    try args_map.put(pp.args[count].str, wss);
                    count += 1;
                }

                for (pp.body) |pp_line| {
                    var idx_: usize = 0;
                    var expansion = try std.ArrayList(Token).initCapacity(self.alloc, pp_line.len);
                    while (idx_ < pp_line.len) : (idx_ += 1) {
                        const pp_t = pp_line[idx_];
                        if (std.mem.startsWith(u8, pp_t.str, MACRO_SYMBOL)) {
                            if (pp_t.str.len == 1)
                                return report_err(pp_t.loc, error.UNEXPECTED_EOF);

                            if (self.macro_map.get(std.mem.trim(u8, pp_t.str[1..pp_t.str.len], " "))) |macro_| {
                                // TODO: Generalize Tokens and []const Ss
                                var ss = try std.ArrayList(Ss).initCapacity(self.alloc, pp_line.len);
                                defer ss.deinit();
                                for (pp_line) |p|
                                    try ss.append(Ss {
                                        .s = p.loc.col,
                                        .str = p.str,
                                    });

                                try self.handle_macro(macro_, row, &idx_, &expansion, ss.items, args_map);
                                continue;
                            } else {
                                print("ERROR: undefined macro: {s}\n", .{pp_t.str});
                                return report_err(pp_t.loc, error.UNDEFINED_MACRO);
                            }
                        } else if (args_map.get(pp_t.str)) |v| {
                            const t = Token.new(type_token_light(v.str), .{
                                .row = row,
                                .col = v.s,
                                .file_path = self.file_path,
                            }, std.mem.trim(u8, v.str, "\""));
                            try expansion.append(t);
                        } else
                            try expansion.append(pp_t);
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
                    if (ty == .str)
                        try line_tokens.append(Token.new(ty, loc, str[1..str.len - 1]))
                    else
                        try line_tokens.append(Token.new(ty, loc, str));
                }
            }
        }
    }

    pub fn lex_file(self: *Self, content: []const u8) anyerror!void {
        var row: u32 = 0;
        var iter = std.mem.splitSequence(u8, content, "\n");
        while (iter.next()) |line_| : (row += 1) {
            if (line_.len == 0 or std.mem.startsWith(u8, line_, COMMENT_SYMBOL)) continue;

            const line = if (std.mem.indexOf(u8, line_, COMMENT_SYMBOL)) |idx|
                line_[0..idx]
            else
                line_;

            const words = try split_whitespace(line, self.alloc);
            var line_tokens = try std.ArrayList(Token).initCapacity(self.alloc, words.len);
            defer self.tokens.append(line_tokens.items) catch exit(1);

            // Found a preprocessor thingy
            if (std.mem.startsWith(u8, line, PP_SYMBOL)) {
                try self.handle_preprocessor(&row, line, words, &iter);
                continue;
            }

            // Found a label
            if (std.ascii.isASCII(line[0]) and std.mem.endsWith(u8, line, ":")) {
                if (words.len > 1)
                    return report_err(Token.Loc.new(row, words[0].s, self.file_path), error.UNDEFINED_SYMBOL);

                const start = words[0].s;
                const label = words[0].str[0..words[0].str.len - 1];

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
                if (std.mem.startsWith(u8, word.str, MACRO_SYMBOL)) {
                    if (word.str.len == 1)
                        return report_err(Token.Loc.new(row, word.s, self.file_path), error.UNEXPECTED_EOF);

                    if (self.macro_map.get(std.mem.trim(u8, word.str[1..word.str.len], " "))) |macro| {
                        try self.handle_macro(macro, row, &idx, &line_tokens, words, null);
                        continue;
                    } else {
                        print("ERROR: undefined macro: {s}\n", .{word.str});
                        return report_err(Token.Loc.new(row, word.s, self.file_path), error.UNDEFINED_MACRO);
                    }
                } else if (std.mem.startsWith(u8, word.str, "#")) {
                    print("Did you mean to use a macro? If so, use '@' instead\n", .{});
                    return report_err(Token.Loc.new(row, word.s, self.file_path), error.UNDEFINED_SYMBOL);
                }

                var ty: Token.Type = undefined;
                if (std.mem.startsWith(u8, word.str, "\"")) {
                    var strs = try std.ArrayList([]const u8).initCapacity(self.alloc, word.str.len);
                    defer strs.deinit();
                    while (true) : (idx += 1) {
                        if (idx >= words.len)
                            return report_err(Token.Loc.new(row, word.s, self.file_path), error.NO_CLOSING_QUOTE);

                        try strs.append(words[idx].str);
                        if (std.mem.endsWith(u8, words[idx].str, "\"")) break;
                    }

                    var str = try std.mem.join(self.alloc, " ", strs.items);
                    str = str[1..str.len - 1];
                    const t = Token.new(.str, Token.Loc.new(row, word.s, self.file_path), str);
                    try line_tokens.append(t);
                    continue;
                }

                if (std.mem.startsWith(u8, word.str, "'")) {
                    if (!std.mem.endsWith(u8, word.str, "'"))
                        return report_err(Token.Loc.new(row, word.s, self.file_path), error.INVALID_CHAR);

                    if (word.str.len != 3)
                        return report_err(Token.Loc.new(row, word.s, self.file_path), error.INVALID_CHAR);

                    const t = Token.new(.char, Token.Loc.new(row, word.s, self.file_path), word.str[1..2]);
                    try line_tokens.append(t);
                    idx += 1;
                }

                if (std.mem.startsWith(u8, word.str, "-")) {
                    if (word.str.len < 2)
                        return report_err(Token.Loc.new(row, word.s, self.file_path), error.UNEXPECTED_EOF);

                    if (!std.ascii.isDigit(word.str[1]))
                        return report_err(Token.Loc.new(row, word.s, self.file_path), error.INVALID_LITERAL);

                    ty = if (std.mem.indexOf(u8, word.str[1..word.str.len], ".") != null)
                        .float
                    else
                        .int;
                }

                if (std.ascii.isDigit(word.str[0])) {
                    ty = if (std.mem.indexOf(u8, word.str, ".") != null)
                        .float
                    else
                        .int;
                } else ty = .literal;

                const t = Token.new(ty, Token.Loc.new(row, word.s, self.file_path), word.str);
                try line_tokens.append(t);
            }
        }
    }

    pub inline fn read_file(file_path: []const u8, alloc: std.mem.Allocator) ![]const u8 {
        return std.fs.cwd().readFileAlloc(alloc, file_path, CONTENT_CAP) catch |err| {
            try panic("ERROR: Failed to read file: {s}: {}", .{file_path, err});
            return err;
        };
    }

    const Ss = struct {
        s: u32,
        str: []const u8,
    };

    fn split_whitespace(input: []const u8, alloc: std.mem.Allocator) ![]const Ss {
        var s: u32 = 0;
        var e: u32 = 0;
        var ret = std.ArrayList(Ss).init(alloc);
        while (e < input.len) : (e += 1)
            if (std.ascii.isWhitespace(input[e])) {
                defer s = e + 1;
                if (s != e)
                    try ret.append(.{
                        .s = s, .str = input[s..e]
                    });
            };

        if (s != e)
            try ret.append(.{
                .s = s, .str = input[s..e]
            });

        return ret.items;
    }
};
