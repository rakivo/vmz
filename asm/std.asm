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
