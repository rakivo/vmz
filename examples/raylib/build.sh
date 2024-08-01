#!/bin/bash

NAME="vmz"
FLAGS="-O ReleaseFast -lc -lraylib -L./lib"
CACHE_DIR="build"

set -xe

zig build-exe ../../src/main.zig $FLAGS -I ../../src --name $NAME --cache-dir $CACHE_DIR
