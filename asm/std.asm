#MEMORY_CAP 8192

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

#fwrite_all_buf buf, fd {
    push buf
    push fd
    push 0
    push buf
    sizeof
    fwrite
}

#fread_all_buf buf, fd {
    push buf
    push fd
    push 0
    push buf
    sizeof
    fread
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
    push @MEMORY_CAP
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
