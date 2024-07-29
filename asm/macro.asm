#"std.asm"

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

_start:
    mem_fread "build.sh"
    mem_fwrite_all "readme.md"
    halt
