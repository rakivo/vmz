" Copyright (C) 2024 Mark Tyrkba <marktyrkba456@gmail.com>

" Author: Mark Tyrkba <marktyrkba456@gmail.com>
" URL: http://github.com/rakivo/mm

" Permission is hereby granted, free of charge, to any person
" obtaining a copy of this software and associated documentation
" files (the "Software"), to deal in the Software without
" restriction, including without limitation the rights to use, copy,
" modify, merge, publish, distribute, sublicense, and/or sell copies
" of the Software, and to permit persons to whom the Software is
" furnished to do so, subject to the following conditions:

" The above copyright notice and this permission notice shall be
" included in all copies or substantial portions of the Software.

" THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
" EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
" MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
" NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
" BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
" ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
" CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
" SOFTWARE.

" masm.vim - Syntax highlighting for MASM assembly code

if exists("b:current_syntax")
  finish
endif

" Define instructions
syn keyword masmInstruction push pop fadd fdiv fsub fmul iadd idiv isub imul inc dec jmp je jne jg jl jle jge swap dup cmp dmp nop label native alloc call ret spush spop read halt fread eread pushmp pushsp dmpln write fwrite jmp_if not sizeof jz jnz

" Define macros starting with #
syn match masmMacro "#[a-zA-Z_][a-zA-Z0-9_]*"

" Define labels
syn match masmLabel "^[a-zA-Z_][a-zA-Z0-9_]*:"

" Define comments starting with ;
syn match masmComment ";.*$"

" Define blocks
syn region masmBlock start=+{+ end=+}+ contains=ALL

" Link the highlighting to Vim's default highlighting groups
hi def link masmInstruction Keyword
hi def link masmMacro PreProc
hi def link masmLabel Constant
hi def link masmComment Comment
hi def link masmBlock Special

let b:current_syntax = "masm"
