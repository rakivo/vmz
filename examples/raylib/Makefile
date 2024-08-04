NAME=vm
VMZ_DIR=vmz
CACHE_DIR=build
VMZ_ZIG_FILES=$(wildcard $(VMZ_DIR)/*.zig)
LIBS=-lc -lraylib
FLAGS=$(LIBS) -L./lib -I./include -O ReleaseFast

all: $(NAME) $(NAME)
	./$(NAME) -p raylib.asm

vm: $(VMZ_ZIG_FILES) main.zig raylib.zig
	zig build-exe main.zig $(FLAGS) --name $(NAME) --cache-dir $(CACHE_DIR)
