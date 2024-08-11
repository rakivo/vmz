; This example is a modificated version of code from here: <https://github.com/tsoding/bm/blob/master/basm/test/cases/pi.basm>
;
; π = (4/1) - (4/3) + (4/5) - (4/7) + (4/9) - (4/11) + (4/13) - (4/15) ...
; Take 4 and subtract 4 divided by 3. Then add 4 divided by 5.
; Then subtract 4 divided by 7. Continue alternating between adding
; and subtracting fractions with a numerator of 4 and a denominator of each
; subsequent odd number. The more times you do this, the closer you will get to pi.

#"std.asm"

#N 7500000

_start:
    push 4.0 ; acc
    push 3.0 ; denominator
    push @N  ; iterations

.loop:
    swap 2   ; swap counter (top of stack) with current acc

    push 4.0
    dup 2
    @fadd 2.0
    swap 3

    fdiv
    fsub

    push 4.0
    dup 2
    @fadd 2.0

    swap 3

    fdiv
    fadd

    swap 2
    dec      ; decrement counter

    push 0
    cmp I64
    jnz .loop

    pop      ; clean the stack and only have pi left
    pop

    dmpln F64
    halt
