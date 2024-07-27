print_file:
    fread
    push 0
.loop:
    eread
    dmp
    pop
    pushmp
    dec
    cmp
    inc
    jl .loop
    ret

_start:
    push "src/lexer.zig"
    call print_file
