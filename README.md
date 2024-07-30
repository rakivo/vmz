# Vm in Zig

# For quick start, we can write a `hello world` in `masm`:
```asm
#"std.asm"

_start:
    @print "hello, world"
```

> Here, you include `"standard"` library with `#"std.asm"`, also, you can create your files and include them as well. Keep in mind, you can pass `-I` flag to the `vm` to specify include path.

> `_start` is just an entry point, like `main` function in other languages.

> With `@` you can call macros, by the way, you can create a macro using following syntax:
```asm
#print what {
    push what
    dmpln
}
```
> After `#` you specify name of the macro, everything that goes after the name and before `{` will be interpreted as arguments, you can use those arguments in the body of the macro, which is specified by curly braces. You can also expand other macros in your macro as in here:
```asm
#C 420

#B @C

#A {
    push @B
}
```
> Unfortunately, you can not expand other multi-line (with curly braces) macro for now, as i didn't add support for that, but you can always send me a PR, I will deeply appreciate any help!
