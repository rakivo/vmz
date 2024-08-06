#"std.asm"

#BUF_CAP 128
#TYPE i64
#VALUE 69
#BUF [@VALUE: @BUF_CAP]

_start:
    @fread_all_buf @BUF, "build.zig.zon"
    @fwrite_all_buf @BUF, "rakivo.asm"
