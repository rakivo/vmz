#!/bin/bash

CACHE_DIR=build
DEFAULT_NAME="vmz"
DEFAULT_FLAGS="-O ReleaseFast"

if [[ -n "$RELEASE" ]]; then
    FLAGS=$DEFAULT_FLAGS
fi

if [[ -z "$NAME" ]]; then
    NAME=$DEFAULT_NAME
fi

set -xe

zig build-lib $FLAGS src/vmz.zig --name $NAME --cache-dir $CACHE_DIR
