#!/bin/bash

NAME="vm"
FLAGS="-lc -lraylib -L./lib -I./include"
CACHE_DIR="build"

printf "Building..\n"

set -xe
zig build-exe main.zig $FLAGS --name $NAME --cache-dir $CACHE_DIR
set +xe

printf "Starting..\n"

./$NAME -p raylib.asm
