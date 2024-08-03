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
> After `#` you specify a name of the macro, everything that goes after the name and before `{` will be interpreted as arguments, you can use those arguments in the body of the macro, which is specified by curly braces. You can also expand other macros in your macro as in here:
```asm
#"std.asm"

#D 69

#C 420

#B @D

#A x {
    @print x
    @print @B
}

_start:
    @A @C
```

> You can also see an example of using [raylib](https://github.com/raysan5/raylib) in (examples/raylib)[https://github.com/rakivo/vmz/tree/master/examples/raylib]

### Credits:
- raylib: <https://github.com/raysan5/raylib>
- modded vec deque: <https://github.com/magurotuna/zig-deque>
