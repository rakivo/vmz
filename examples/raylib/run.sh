#!/bin/bash

NAME="vm"
FLAGS="-lc -lraylib -L./lib -I./include"
CACHE_DIR="build"

printf "Building..\n"

set -x

zig build-exe main.zig $FLAGS --name $NAME --cache-dir $CACHE_DIR

set +x

printf "Starting..\n"
printf "To close the window press C-c (ctrl + c).\n"

set -x

./$NAME -p raylib.asm
