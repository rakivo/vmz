set -xe

nasm $FILENAME.asm $NASMFLAGS -f elf64 -g -F dwarf
ld -o $FILENAME $FILENAME.o
time ./$FILENAME
