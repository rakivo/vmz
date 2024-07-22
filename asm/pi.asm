_start:
    push 4.0
    push 3.0
    push 750000
.loop:
    swap 2
    push 4.0
    dup 2
    push 2.0
    fadd
    swap 3
    fdiv
    fsub
    push 4.0
    dup 2
    push 2.0
    fadd
    swap 3
    fdiv
    fadd
    swap 2
    dec
    push 0
    cmp
    jne .loop
    pop
    pop
    dmp
