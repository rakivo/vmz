CACHE_DIR=build

set -xe

zig build-exe $FLAGS src/main.zig --cache-dir $CACHE_DIR
