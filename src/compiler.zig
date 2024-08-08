const std      = @import("std");
const vm_mod   = @import("vm.zig");
const inst_mod = @import("inst.zig");
const NaNBox   = @import("NaNBox.zig").NaNBox;

const Inst = inst_mod.Inst;

const panic = vm_mod.panic;

const exit = std.process.exit;
const print = std.debug.print;

pub const Compiler = struct {
    alloc: std.mem.Allocator,
    program: []const Inst,
    file_path: []const u8,
    writer: std.fs.File.Writer,

    const Self = @This();

    pub fn new(alloc: std.mem.Allocator, program: []const Inst, file_path: []const u8) !Self {
        return .{
            .alloc = alloc,
            .program = program,
            .file_path = file_path,
            .writer = (try std.fs.cwd().createFile(file_path, .{})).writer()
        };
    }

    inline fn wt(self: *const Self, bytes: []const u8) void {
        self.w("    " ++ bytes);
    }

    inline fn w(self: *const Self, bytes: []const u8) void {
        self.writer.writeAll(bytes ++ "\n") catch |err| {
            print("ERROR: Failed to write to file {s}: {}", .{self.file_path, err});
            exit(1);
        };
    }

    inline fn wprint(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt ++ "\n", args) catch |err| {
            print("ERROR: Failed to write to file {s}: {}", .{self.file_path, err});
            exit(1);
        };
    }

    inline fn wprintt(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.wprint("    " ++ fmt, args);
    }

    pub fn compile_inst(self: *const Self, inst: *const Inst) void {
        self.wprint("; {s} {}", .{inst.type.to_str(), inst.value});
        switch (inst.type) {
            .push => switch (inst.value) {
                .I64 => |int| {
                    self.wt("mov rsi, qword [stack_ptr]");
                    self.wprintt("mov qword [rsi], {d}", .{int});
                    self.wt("add [stack_ptr], WORD_SIZE");
                },
                .U64 => |int| {
                    self.wt("mov rsi, qword [stack_ptr]");
                    self.wprintt("mov qword [rsi], {d}", .{int});
                    self.wt("add [stack_ptr], WORD_SIZE");
                },
                .F64 => |float| {
                    _ = float;
                    self.wt("mov rax, [FLOAT]");
                    self.wt("mov rsi, qword [stack_ptr]");
                    self.wprintt("mov qword [rsi], rax", .{});
                    self.wt("add [stack_ptr], WORD_SIZE");
                },
                .NaN => |nan| switch (nan.getType()) {
                    .I64, .U64 => {
                        self.wt("mov rsi, qword [stack_ptr]");
                        self.wprintt("mov qword [rsi], {d}", .{nan.as(i64)});
                        self.wt("add [stack_ptr], WORD_SIZE");
                    },
                    .F64 => {
                        self.wt("mov rax, [FLOAT]");
                        self.wt("mov rsi, qword [stack_ptr]");
                        self.wprintt("mov qword [rsi], rax", .{});
                        self.wt("add [stack_ptr], WORD_SIZE");
                    },
                    else => panic("Unimplemented", .{})
                },
                else => panic("Unimplemented", .{})
            },
            .iadd => {
                self.wt("mov rsi, [stack_ptr]");
                self.wt("sub rsi, WORD_SIZE");
                self.wt("mov rbx, [rsi]");
                self.wt("mov rax, [rsi - WORD_SIZE]");
                self.wt("add rax, rbx");
                self.wt("mov [rsi], rax");
            },
            .fadd => {
                self.wt("mov rsi, [stack_ptr]");
                self.wt("sub rsi, WORD_SIZE");
                self.wt("mov rbx, [rsi]");
                self.wt("mov rax, [rsi - WORD_SIZE]");
                self.wt("movq xmm0, rax");
                self.wt("movq xmm1, rbx");
                self.wt("mulsd xmm0, xmm1");
                self.wt("movq rax, xmm0");
                self.wt("mov [rsi], rax");
            },
            .dmpln => {
                self.wt("mov rsi, [stack_ptr]");
                self.wt("mov rax, [rsi - 8]");
                self.wt("movq xmm1, rax");
                self.wt("cvttsd2si rdi, xmm0");
                self.wt("call dmp_i64");
                // self.wt("mov rsi, qword [stack_ptr]");
                // self.wt("sub rsi, WORD_SIZE");
                // self.wt("mov rdi, qword [rsi]");
                // self.wt("call dmp_i64");
            },
            .label => self.wprint("{s}:", .{inst.value.Str}),
            .halt => {
                self.wt("mov rax, 60");
                self.wt("xor rdi, rdi");
                self.wt("syscall");
            },
            else => {}
        }
    }

    pub fn compile(self: *const Self) !void {
        self.w("format ELF64");
        self.w("define STACK_CAP 1024");
        self.w("define WORD_SIZE 8");
        self.w("section '.text' executable");
        self.w("dmp_i64:");
        self.w("    push    rbp");
        self.w("    mov     rbp, rsp");
        self.w("    sub     rsp, 64");
        self.w("    mov     qword [rbp - 8], rdi");
        self.w("    mov     dword [rbp - 36], 0");
        self.w("    mov     dword [rbp - 40], 0");
        self.w("    cmp     qword [rbp - 8], 0");
        self.w("    jge     .LBB0_2");
        self.w("    mov     dword [rbp - 40], 1");
        self.w("    xor     eax, eax");
        self.w("    sub     rax, qword [rbp - 8]");
        self.w("    mov     qword [rbp - 8], rax");
        self.w(".LBB0_2:");
        self.w("    cmp     qword [rbp - 8], 0");
        self.w("    jne     .LBB0_4");
        self.w("    mov     eax, dword [rbp - 36]");
        self.w("    mov     ecx, eax");
        self.w("    add     ecx, 1");
        self.w("    mov     dword [rbp - 36], ecx");
        self.w("    cdqe");
        self.w("    mov     byte [rbp + rax - 32], 48");
        self.w("    jmp     .LBB0_8");
        self.w(".LBB0_4:");
        self.w("    jmp     .LBB0_5");
        self.w(".LBB0_5:");
        self.w("    cmp     qword [rbp - 8], 0");
        self.w("    jle     .LBB0_7");
        self.w("    mov     rax, qword [rbp - 8]");
        self.w("    mov     ecx, 10");
        self.w("    cqo");
        self.w("    idiv    rcx");
        self.w("    mov     eax, edx");
        self.w("    mov     dword [rbp - 44], eax");
        self.w("    mov     eax, dword [rbp - 44]");
        self.w("    add     eax, 48");
        self.w("    mov     cl, al");
        self.w("    mov     eax, dword [rbp - 36]");
        self.w("    mov     edx, eax");
        self.w("    add     edx, 1");
        self.w("    mov     dword [rbp - 36], edx");
        self.w("    cdqe");
        self.w("    mov     byte [rbp + rax - 32], cl");
        self.w("    mov     rax, qword [rbp - 8]");
        self.w("    mov     ecx, 10");
        self.w("    cqo");
        self.w("    idiv    rcx");
        self.w("    mov     qword [rbp - 8], rax");
        self.w("    jmp     .LBB0_5");
        self.w(".LBB0_7:");
        self.w("    jmp     .LBB0_8");
        self.w(".LBB0_8:");
        self.w("    cmp     dword [rbp - 40], 0");
        self.w("    je      .LBB0_10");
        self.w("    mov     eax, dword [rbp - 36]");
        self.w("    mov     ecx, eax");
        self.w("    add     ecx, 1");
        self.w("    mov     dword [rbp - 36], ecx");
        self.w("    cdqe");
        self.w("    mov     byte [rbp + rax - 32], 45");
        self.w(".LBB0_10:");
        self.w("    movsxd  rax, dword [rbp - 36]");
        self.w("    mov     byte [rbp + rax - 32], 0");
        self.w("    mov     dword [rbp - 48], 0");
        self.w("    mov     eax, dword [rbp - 36]");
        self.w("    sub     eax, 1");
        self.w("    mov     dword [rbp - 52], eax");
        self.w(".LBB0_11:");
        self.w("    mov     eax, dword [rbp - 48]");
        self.w("    cmp     eax, dword [rbp - 52]");
        self.w("    jge     .LBB0_13");
        self.w("    movsxd  rax, dword [rbp - 48]");
        self.w("    mov     al, byte [rbp + rax - 32]");
        self.w("    mov     byte [rbp - 53], al");
        self.w("    movsxd  rax, dword [rbp - 52]");
        self.w("    mov     cl, byte [rbp + rax - 32]");
        self.w("    movsxd  rax, dword [rbp - 48]");
        self.w("    mov     byte [rbp + rax - 32], cl");
        self.w("    mov     cl, byte [rbp - 53]");
        self.w("    movsxd  rax, dword [rbp - 52]");
        self.w("    mov     byte [rbp + rax - 32], cl");
        self.w("    mov     eax, dword [rbp - 48]");
        self.w("    add     eax, 1");
        self.w("    mov     dword [rbp - 48], eax");
        self.w("    mov     eax, dword [rbp - 52]");
        self.w("    add     eax, -1");
        self.w("    mov     dword [rbp - 52], eax");
        self.w("    jmp     .LBB0_11");
        self.w(".LBB0_13:");
        self.w("    mov     eax, dword [rbp - 36]");
        self.w("    mov     ecx, eax");
        self.w("    add     ecx, 1");
        self.w("    mov     dword [rbp - 36], ecx");
        self.w("    cdqe");
        self.w("    mov     byte [rbp + rax - 32], 10");
        self.w("    lea     rsi, [rbp - 32]");
        self.w("    movsxd  rdx, dword [rbp - 36]");
        self.w("    mov     edi, 1");
        self.w("    mov     eax, 1");
        self.w("    syscall");
        self.w("    add     rsp, 64");
        self.w("    pop     rbp");
        self.w("    ret");
        self.w("public _start");

        for (self.program) |inst| self.compile_inst(&inst);

        self.w("section '.data' writeable");
        self.w("stack_ptr dq stack_buf");
        self.w("stack_buf rq STACK_CAP");
        self.w("FLOAT dq 3.14");
    }
};
