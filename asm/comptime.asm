#"std.asm"

#BUF_CAP 5
#TYPE i64
#VALUE 69
#BUF [i32: @BUF_CAP]

_start:
    push @BUF
    push 0
    push 420
    fwrite
    ; @fread "readme.md"
