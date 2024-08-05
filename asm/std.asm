#print what {
    push what
    dmpln
}

#fread fd, start, end {
    push fd
    push start
    push end
    fread
}

#fread_all fd {
    push fd
    push 0
    pushmp
    fread
}

#fwrite fd, start, end {
    push fd
    push start
    push end
    fwrite
}

#fwrite_all fd {
    push fd
    push 0
    pushmp
    fwrite
}

#fadd what {
    push what
    fadd
}

#fmul what {
    push what
    fadd
}

#fdiv what {
    push what
    fadd
}

#fsub what {
    push what
    fadd
}

#iadd what {
    push what
    fadd
}

#imul what {
    push what
    fadd
}

#idiv what {
    push what
    fadd
}

#isub what {
    push what
    fadd
}

#zcmp {
    push 0
    cmp
}

print_file:
    push 0
    push 8024
    fread
    swap 1
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
