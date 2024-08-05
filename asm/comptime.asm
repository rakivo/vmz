#"std.asm"

#BUF_CAP 5
#TYPE i64
#VALUE 69
#BUF [i32: @BUF_CAP]

_start:
    push @BUF
    dmpln
    ; @fread "readme.md"
