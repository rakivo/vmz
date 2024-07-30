#print what {
    push what
    dmpln
}

#mem_fread fd {
    push fd
    fread
}

#mem_fwrite_all fd {
    push fd
    push 0
    pushmp
    fwrite
}

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
