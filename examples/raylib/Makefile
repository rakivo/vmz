NAME=vm
VMZ_DIR=vmz
CACHE_DIR=build
VMZ_ZIG_FILES=$(wildcard $(VMZ_DIR)/*.zig)
FLAGS=-lc -lraylib -L./lib -I./include -O ReleaseFast

all: vm
	./$(NAME) -p raylib.asm

vm: $(VMZ_ZIG_FILES) main.zig raylib.zig
	zig build-exe main.zig $(FLAGS) --name $(NAME) --cache-dir $(CACHE_DIR)
