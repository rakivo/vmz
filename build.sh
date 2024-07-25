#!/bin/bash

CACHE_DIR=build

if [[ -n "$RELEASE" ]]; then
    FLAGS="-O ReleaseFast"
fi

if [[ -z "$NAME" ]]; then
    NAME="vm"
fi

set -xe

zig build-exe $FLAGS src/main.zig --name $NAME --cache-dir $CACHE_DIR
