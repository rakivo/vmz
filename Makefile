NAME=vmz
SRC_DIR=src
CACHE_DIR=build
ROOT_FILE=src/vmz.zig
ZIG_FILES=$(wildcard $(SRC_DIR)/*.zig)
FLAGS=--name $(NAME) --cache-dir $(CACHE_DIR)

ifeq ($(RELEASE), 1)
	FLAGS += -O ReleaseFast
endif

test: test.zig $(ZIG_FILES)
	zig build-exe $< $(FLAGS)

libvmz.a: $(ZIG_FILES)
	zig build-lib $(ROOT_FILE) $(FLAGS)
