CACHE_DIR=build

set -xe

zig build-exe $FLAGS main.zig --cache-dir $CACHE_DIR
