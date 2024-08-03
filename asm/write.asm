#"std.asm"

_start:
    @fread "README.md"
    @fwrite_all "readme.md"
