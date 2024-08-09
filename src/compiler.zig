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

    pub fn compile_inst2nasm(self: *const Self, inst: *const Inst, float_counter: *u64, is_fcmp: *bool) void {
        self.wprint("; {s} {}", .{inst.type.to_str(), inst.value});
        switch (inst.type) {
            .push => switch (inst.value) {
                .I64 => |int| {
                    self.wt("mov r15, qword [stack_ptr]");
                    self.wprintt("mov qword [r15], 0x{X}", .{int});
                    self.wt("add qword [stack_ptr], WORD_SIZE");
                },
                .U64 => |int| {
                    self.wt("mov r15, qword [stack_ptr]");
                    self.wprintt("mov qword [r15], 0x{X}", .{int});
                    self.wt("add qword [stack_ptr], WORD_SIZE");
                },
                .F64 => |_| {
                    defer float_counter.* += 1;
                    self.wprintt("mov rax, [__f{d}__]", .{float_counter.*});
                    self.wt("mov r15, qword [stack_ptr]");
                    self.wt("mov qword [r15], rax");
                    self.wt("add qword [stack_ptr], WORD_SIZE");
                },
                .NaN => |nan| switch (nan.getType()) {
                    .I64, .U64 => {
                        self.wt("mov r15, qword [stack_ptr]");
                        self.wprintt("mov qword [r15], 0x{X}", .{nan.as(i64)});
                        self.wt("add qword [stack_ptr], WORD_SIZE");
                    },
                    .F32, .F64 => {
                        defer float_counter.* += 1;
                        self.wprintt("mov rax, [__f{d}__]", .{float_counter.*});
                        self.wt("mov r15, qword [stack_ptr]");
                        self.wprintt("mov qword [r15], rax", .{});
                        self.wt("add qword [stack_ptr], WORD_SIZE");
                    },
                    inline else => panic("Unimplemented", .{})
                },
                inline else => panic("Unimplemented", .{})
            },
            .pop => self.wt("sub qword [stack_ptr], WORD_SIZE"),
            .iadd => {
                self.wt("mov r15, [stack_ptr]");
                self.wt("sub r15, WORD_SIZE");
                self.wt("mov rbx, [r15]");
                self.wt("mov rax, [r15 - WORD_SIZE]");
                self.wt("add rax, rbx");
                self.wt("mov [r15 - WORD_SIZE], rax");
                self.wt("mov [stack_ptr], r15");
            },
            .imul => {
                self.wt("mov r15, [stack_ptr]");
                self.wt("sub r15, WORD_SIZE");
                self.wt("mov rbx, [r15]");
                self.wt("mov rax, [r15 - WORD_SIZE]");
                self.wt("xor edx, edx");
                self.wt("imul rbx");
                self.wt("mov [r15 - WORD_SIZE], rax");
                self.wt("mov [stack_ptr], r15");
            },
            .idiv => {
                self.wt("mov r15, [stack_ptr]");
                self.wt("sub r15, WORD_SIZE");
                self.wt("mov rbx, [r15]");
                self.wt("mov rax, [r15 - WORD_SIZE]");
                self.wt("xor edx, edx");
                self.wt("idiv rbx");
                self.wt("mov [r15 - WORD_SIZE], rax");
                self.wt("mov [stack_ptr], r15");
            },
            .isub => {
                self.wt("mov r15, [stack_ptr]");
                self.wt("sub r15, WORD_SIZE");
                self.wt("mov rbx, [r15]");
                self.wt("mov rax, [r15 - WORD_SIZE]");
                self.wt("sub rax, rbx");
                self.wt("mov qword [r15 - WORD_SIZE], rax");
                self.wt("mov qword [stack_ptr], r15");
            },
            .fmul => {
                self.wt("mov r15, qword [stack_ptr]");
                self.wt("sub r15, WORD_SIZE");
                self.wt("mov rbx, qword [r15]");
                self.wt("mov rax, qword [r15 - WORD_SIZE]");
                self.wt("movq xmm0, rax");
                self.wt("movq xmm1, rbx");
                self.wt("mulsd xmm0, xmm1");
                self.wt("movq [r15 - WORD_SIZE], xmm0");
                self.wt("mov qword [stack_ptr], r15");
            },
            .fdiv => {
                self.wt("mov r15, qword [stack_ptr]");
                self.wt("sub r15, WORD_SIZE");
                self.wt("mov rbx, qword [r15]");
                self.wt("mov rax, qword [r15 - WORD_SIZE]");
                self.wt("movq xmm0, rax");
                self.wt("movq xmm1, rbx");
                self.wt("divsd xmm0, xmm1");
                self.wt("movq [r15 - WORD_SIZE], xmm0");
                self.wt("mov [stack_ptr], r15");
            },
            .fadd => {
                self.wt("mov r15, [stack_ptr]");
                self.wt("sub r15, WORD_SIZE");
                self.wt("mov rbx, [r15]");
                self.wt("mov rax, [r15 - WORD_SIZE]");
                self.wt("movq xmm0, rax");
                self.wt("movq xmm1, rbx");
                self.wt("addsd xmm0, xmm1");
                self.wt("movq [r15 - WORD_SIZE], xmm0");
                self.wt("mov [stack_ptr], r15");
            },
            .fsub => {
                self.wt("mov r15, [stack_ptr]");
                self.wt("sub r15, WORD_SIZE");
                self.wt("mov rbx, [r15]");
                self.wt("mov rax, [r15 - WORD_SIZE]");
                self.wt("movq xmm0, rax");
                self.wt("movq xmm1, rbx");
                self.wt("subsd xmm0, xmm1");
                self.wt("movq [r15 - WORD_SIZE], xmm0");
                self.wt("mov [stack_ptr], r15");
            },
            .dmpln => switch (inst.value.Type) {
                .F64 => {
                    self.wt("mov r15, [stack_ptr]");
                    self.wt("mov rax, [r15 - WORD_SIZE]");
                    self.wt("movq xmm0, rax");
                    self.wt("call dmp_f64");
                },
                .U8, .U64, .I64 => {
                    self.wt("mov r15, qword [stack_ptr]");
                    self.wt("mov rdi, qword [r15 - WORD_SIZE]");
                    self.wt("call dmp_i64");
                },
                .None => {},
                inline else => panic("Printing type: {} it not implemented yet..", .{inst.value.Type})
            },
            .dec => {
                self.wt("mov r15, [stack_ptr]");
                self.wt("sub r15, WORD_SIZE");
                self.wt("mov rax, [r15]");
                self.wt("dec rax");
                self.wt("mov [r15], rax");
            },
            .inc => {
                self.wt("mov r15, [stack_ptr]");
                self.wt("sub r15, WORD_SIZE");
                self.wt("mov rax, [r15]");
                self.wt("inc rax");
                self.wt("mov [r15], rax");
            },
            .cmp => switch (inst.value.Type) {
                .F64 => {
                    self.wt("mov r15, [stack_ptr]");
                    self.wt("sub r15, WORD_SIZE");
                    self.wt("mov rax, [r15]");
                    self.wt("mov rbx, [r15 - WORD_SIZE]");
                    self.wt("movq xmm0, rax");
                    self.wt("movq xmm1, rbx");
                    self.wt("sub qword [stack_ptr], WORD_SIZE");
                    self.wt("comisd xmm1, xmm0");
                    is_fcmp.* = true;
                },
                .U8, .U64, .I64 => {
                    self.wt("mov r15, [stack_ptr]");
                    self.wt("sub r15, WORD_SIZE");
                    self.wt("mov rax, [r15]");
                    self.wt("mov rbx, [r15 - WORD_SIZE]");
                    self.wt("sub qword [stack_ptr], WORD_SIZE");
                    self.wt("cmp rbx, rax");
                    is_fcmp.* = false;
                },
                inline else => panic("Comparing type: {} it not implemented yet..", .{inst.value.Type})
            },
            .swap => {
                const idx: u64 = switch (inst.value) {
                    .U8  => |int| @intCast(int),
                    .U64 => |int| int,
                    .I64 => |int| @intCast(int),
                    else => panic("INVALID TYPE BRUH", .{})
                };
                self.wt("mov r15, [stack_ptr]");
                self.wt("sub r15, 8");
                self.wt("mov rax, [r15]");
                self.wprintt("mov rbx, [r15 - WORD_SIZE * {d}]", .{idx});
                self.wt("mov [r15], rbx");
                self.wprintt("mov [r15 - WORD_SIZE * {d}], rax", .{idx});
            },
            .dup => {
                const idx: u64 = switch (inst.value) {
                    .U8  => |int| @intCast(int),
                    .U64 => |int| int,
                    .I64 => |int| @intCast(int),
                    else => panic("INVALID TYPE BRUH", .{})
                };
                self.wt("mov r15, qword [stack_ptr]");
                self.wprintt("mov rax, qword [r15 - WORD_SIZE - WORD_SIZE * {d}]", .{idx});
                self.wt("mov qword [r15], rax");
                self.wt("add qword [stack_ptr], WORD_SIZE");
            },
            .jl => if (is_fcmp.*) self.wprintt("jb {s}", .{inst.value.Str})
                   else           self.wprintt("jl {s}", .{inst.value.Str}),
            .jg => if (is_fcmp.*) self.wprintt("ja {s}", .{inst.value.Str})
                   else           self.wprintt("jg {s}", .{inst.value.Str}),
            .jle => if (is_fcmp.*) {
                self.wprintt("jb {s}", .{inst.value.Str});
                self.wprintt("je {s}", .{inst.value.Str});
            } else self.wprintt("jle {s}", .{inst.value.Str}),
            .jge => if (is_fcmp.*) {
                self.wprintt("ja {s}", .{inst.value.Str});
                self.wprintt("je {s}", .{inst.value.Str});
            } else self.wprintt("jge {s}", .{inst.value.Str}),
            .jmp, .jnz, .je, .jne => self.wprintt("{s} {s}", .{inst.type.to_str(), inst.value.Str}),
            .halt => {
                self.wt("mov rax, SYS_EXIT");
                self.wt("xor rdi, rdi");
                self.wt("syscall");
            },
            .label => self.wprint("{s}:", .{inst.value.Str}),
            inline else => panic("{s} is unimplemented yet..", .{inst.type.to_str()})
        }
    }

    pub fn compile2nasm(self: *const Self) !void {
        self.w("BITS 64");
        self.w("%define STACK_CAP  1024");
        self.w("%define WORD_SIZE  8");
        self.w("%define SYS_WRITE  1");
        self.w("%define SYS_STDOUT 1");
        self.w("%define SYS_EXIT   60");
        self.w("segment .text");
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
        self.w("    mov     eax, SYS_WRITE");
        self.w("    mov     edi, SYS_STDOUT");
        self.w("    syscall");
        self.w("    add     rsp, 64");
        self.w("    pop     rbp");
        self.w("    ret");
        self.w("dmp_f64:");
        self.w("    push    rbp");
        self.w("    mov     rbp, rsp");
        self.w("    sub     rsp, 128");
        self.w("    movsd   qword [rbp - 8], xmm0");
        self.w("    mov     dword [rbp - 52], 0");
        self.w("    xorps   xmm0, xmm0");
        self.w("    ucomisd xmm0, qword [rbp - 8]");
        self.w("    jbe     .LBB0_2");
        self.w("    mov     eax, dword [rbp - 52]");
        self.w("    mov     ecx, eax");
        self.w("    add     ecx, 1");
        self.w("    mov     dword [rbp - 52], ecx");
        self.w("    cdqe");
        self.w("    mov     byte [rbp + rax - 48], 45");
        self.w("    movsd   xmm0, qword [rbp - 8]");
        self.w("    movq    rax, xmm0");
        self.w("    mov  rcx, -9223372036854775808");
        self.w("    xor     rax, rcx");
        self.w("    movq    xmm0, rax");
        self.w("    movsd   qword [rbp - 8], xmm0");
        self.w(".LBB0_2:");
        self.w("    cvttsd2si       eax, qword [rbp - 8]");
        self.w("    mov     dword [rbp - 56], eax");
        self.w("    movsd   xmm0, qword [rbp - 8]");
        self.w("    cvtsi2sd        xmm1, dword [rbp - 56]");
        self.w("    subsd   xmm0, xmm1");
        self.w("    movsd   qword [rbp - 64], xmm0");
        self.w("    cmp     dword [rbp - 56], 0");
        self.w("    jne     .LBB0_4");
        self.w("    mov     eax, dword [rbp - 52]");
        self.w("    mov     ecx, eax");
        self.w("    add     ecx, 1");
        self.w("    mov     dword [rbp - 52], ecx");
        self.w("    cdqe");
        self.w("    mov     byte [rbp + rax - 48], 48");
        self.w("    jmp     .LBB0_12");
        self.w(".LBB0_4:");
        self.w("    mov     dword [rbp - 116], 0");
        self.w(".LBB0_5:");
        self.w("    cmp     dword [rbp - 56], 0");
        self.w("    jle     .LBB0_7");
        self.w("    mov     eax, dword [rbp - 56]");
        self.w("    mov     ecx, 10");
        self.w("    cdq");
        self.w("    idiv    ecx");
        self.w("    mov     eax, dword [rbp - 116]");
        self.w("    mov     ecx, eax");
        self.w("    add     ecx, 1");
        self.w("    mov     dword [rbp - 116], ecx");
        self.w("    cdqe");
        self.w("    mov     dword [rbp + 4*rax - 112], edx");
        self.w("    mov     eax, dword [rbp - 56]");
        self.w("    mov     ecx, 10");
        self.w("    cdq");
        self.w("    idiv    ecx");
        self.w("    mov     dword [rbp - 56], eax");
        self.w("    jmp     .LBB0_5");
        self.w(".LBB0_7:");
        self.w("    mov     eax, dword [rbp - 116]");
        self.w("    sub     eax, 1");
        self.w("    mov     dword [rbp - 120], eax");
        self.w(".LBB0_8:");
        self.w("    cmp     dword [rbp - 120], 0");
        self.w("    jl      .LBB0_11");
        self.w("    movsxd  rax, dword [rbp - 120]");
        self.w("    mov     eax, dword [rbp + 4*rax - 112]");
        self.w("    add     eax, 48");
        self.w("    mov     cl, al");
        self.w("    mov     eax, dword [rbp - 52]");
        self.w("    mov     edx, eax");
        self.w("    add     edx, 1");
        self.w("    mov     dword [rbp - 52], edx");
        self.w("    cdqe");
        self.w("    mov     byte [rbp + rax - 48], cl");
        self.w("    mov     eax, dword [rbp - 120]");
        self.w("    add     eax, -1");
        self.w("    mov     dword [rbp - 120], eax");
        self.w("    jmp     .LBB0_8");
        self.w(".LBB0_11:");
        self.w("    jmp     .LBB0_12");
        self.w(".LBB0_12:");
        self.w("    mov     eax, dword [rbp - 52]");
        self.w("    mov     ecx, eax");
        self.w("    add     ecx, 1");
        self.w("    mov     dword [rbp - 52], ecx");
        self.w("    cdqe");
        self.w("    mov     byte [rbp + rax - 48], 46");
        self.w("    mov     dword [rbp - 124], 0");
        self.w(".LBB0_13:");
        self.w("    cmp     dword [rbp - 124], 10");
        self.w("    jge     .LBB0_16");
        self.w("    mov     rax,  0x4024000000000000");
        self.w("    movq    xmm0, rax");
        self.w("    mulsd   xmm0, qword [rbp - 64]");
        self.w("    movsd   qword [rbp - 64], xmm0");
        self.w("    cvttsd2si       eax, qword [rbp - 64]");
        self.w("    mov     dword [rbp - 128], eax");
        self.w("    mov     eax, dword [rbp - 128]");
        self.w("    add     eax, 48");
        self.w("    mov     cl, al");
        self.w("    mov     eax, dword [rbp - 52]");
        self.w("    mov     edx, eax");
        self.w("    add     edx, 1");
        self.w("    mov     dword [rbp - 52], edx");
        self.w("    cdqe");
        self.w("    mov     byte [rbp + rax - 48], cl");
        self.w("    cvtsi2sd        xmm1, dword [rbp - 128]");
        self.w("    movsd   xmm0, qword [rbp - 64]");
        self.w("    subsd   xmm0, xmm1");
        self.w("    movsd   qword [rbp - 64], xmm0");
        self.w("    mov     eax, dword [rbp - 124]");
        self.w("    add     eax, 1");
        self.w("    mov     dword [rbp - 124], eax");
        self.w("    jmp     .LBB0_13");
        self.w(".LBB0_16:");
        self.w("    mov     eax, dword [rbp - 52]");
        self.w("    mov     ecx, eax");
        self.w("    add     ecx, 1");
        self.w("    mov     dword [rbp - 52], ecx");
        self.w("    cdqe");
        self.w("    mov     byte [rbp + rax - 48], 10");
        self.w("    lea     rsi, [rbp - 48]");
        self.w("    movsxd  rdx, dword [rbp - 52]");
        self.w("    mov     eax, 1");
        self.w("    mov     edi, 1");
        self.w("    syscall");
        self.w("    add     rsp, 128");
        self.w("    pop     rbp");
        self.w("    ret");
        self.w("global _start");

        var is_fcmp = false;
        var float_counter: u64 = 0;
        for (self.program) |inst| {
            self.compile_inst2nasm(&inst, &float_counter, &is_fcmp);
        }

        self.w("segment .data");
        float_counter = 0;
        for (self.program) |inst| {
            switch (inst.value) {
                .F64 => |f| {
                    self.wprint("__f{d}__ dq 0x{X}", .{float_counter, @as(u64, @bitCast(f))});
                    float_counter += 1;
                },
                .NaN => |nan| if (nan.getType() == .F32 or nan.getType() == .F64) {
                    self.wprint("__f{d}__ dq 0x{X}", .{float_counter, @as(u64, @bitCast(nan.as(f64)))});
                    float_counter += 1;
                },
                inline else => {}
            }
        }
        self.w("stack_ptr dq stack_buf");
        self.w("segment .bss");
        self.w("stack_buf resq STACK_CAP");
    }
};
