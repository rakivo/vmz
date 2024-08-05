NAME=vmz
SRC_DIR=src
CACHE_DIR=build
ROOT_FILE=src/vmz.zig
ZIG_FILES=$(wildcard $(SRC_DIR)/*.zig)
FLAGS=--name $(NAME) --cache-dir $(CACHE_DIR)
CROSS_COMPILE_FLAGS=$(FLAGS) -target x86_64-windows

ifeq ($(RELEASE), 1)
	FLAGS += -O ReleaseFast
endif

all: vmz_linux vmz_windows

vmz_linux: vmz
vmz: vmz.zig $(ZIG_FILES)
	zig build-exe $< $(FLAGS)

vmz_windows: vmz.exe
vmz.exe: vmz.zig $(ZIG_FILES)
	zig build-exe $< $(CROSS_COMPILE_FLAGS)

libvmz.a: $(ZIG_FILES)
	zig build-lib $(ROOT_FILE) $(FLAGS)

clean:
	rm -f $(NAME).exe $(NAME) $(NAME).o $(NAME).exe.obj libvmz.a.o libvmz.a $(NAME).pdb
