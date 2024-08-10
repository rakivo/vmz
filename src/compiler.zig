const std      = @import("std");
const vm_mod   = @import("vm.zig");
const inst_mod = @import("inst.zig");
const NaNBox   = @import("NaNBox.zig").NaNBox;

const InstValue = inst_mod.InstValue;
const Inst      = inst_mod.Inst;

const panic     = vm_mod.panic;

const exit      = std.process.exit;
const print     = std.debug.print;

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

    inline fn stack_last_three(self: *const Self) void {
        self.wt("mov r15, qword [stack_ptr]");
        self.wt("mov rax, qword [r15 - WORD_SIZE]");
        self.wt("mov rbx, qword [r15 - WORD_SIZE * 2]");
        self.wt("mov rdx, qword [r15 - WORD_SIZE * 3]");
    }

    inline fn stack_last_two(self: *const Self) void {
        self.wt("mov r15, qword [stack_ptr]");
        self.wt("mov rax, qword [r15 - WORD_SIZE]");
        self.wt("mov rbx, qword [r15 - WORD_SIZE * 2]");
    }

    inline fn stack_last(self: *const Self) void {
        self.wt("mov r15, qword [stack_ptr]");
        self.wt("mov rax, qword [r15 - WORD_SIZE]");
    }

    inline fn stack_last_xmm(self: *const Self) void {
        self.wt("mov r15, qword [stack_ptr]");
        self.wt("mov rax, qword [r15 - WORD_SIZE]");
        self.wt("movq xmm0, rax");
    }

    inline fn stack_last_two_xmm(self: *const Self) void {
        self.wt("mov r15, qword [stack_ptr]");
        self.wt("mov rbx, qword [r15 - WORD_SIZE]");
        self.wt("mov rax, qword [r15 - WORD_SIZE * 2]");
        self.wt("movq xmm0, rax");
        self.wt("movq xmm1, rbx");
    }

    inline fn binop_f64(self: *const Self, op: []const u8) void {
        self.wprintt("{s} xmm0, xmm1", .{op});
        self.wt("movq [r15 - WORD_SIZE * 2], xmm0");
        self.wt("sub qword [stack_ptr], WORD_SIZE");
    }

    inline fn stack_push_i64(self: *const Self, comptime T: type, v: T) void {
        self.wt("mov r15, qword [stack_ptr]");
        self.wprintt("mov qword [r15], 0x{X}", .{v});
        self.wt("add qword [stack_ptr], WORD_SIZE");
    }

    inline fn stack_push_f64(self: *const Self, fltc: u64) void {
        self.wt("mov r15, qword [stack_ptr]");
        self.wprintt("mov rax, [__f{d}__]", .{fltc});
        self.wt("mov [r15], rax");
        self.wt("add qword [stack_ptr], WORD_SIZE");
    }

    inline fn stack_mov_to_2nd_from_end_i64(self: *const Self, what: []const u8) void {
        self.wprintt("mov [r15 - WORD_SIZE * 2], {s}", .{what});
        self.wt("sub qword [stack_ptr], WORD_SIZE");
    }

    inline fn get_u64_idc(instv: InstValue) u64 {
        return switch (instv) {
            .U8  => |int| @intCast(int),
            .U64 => |int| int,
            .I64 => |int| @intCast(int),
            .NaN => |nan| switch (nan.getType()) {
                .I8, .I32, .I64, .U8, .U32, .U64 => nan.as(u64),
                inline else => panic("INVALID TYPE BRUH", .{})
            },
            inline else => panic("INVALID TYPE BRUH", .{})
        };
    }

    pub fn compile_inst2nasm(self: *const Self, inst: *const Inst, float_counter: *u64, is_fcmp: *bool) void {
        self.wprint("; {s} {}", .{inst.type.to_str(), inst.value});
        switch (inst.type) {
            .push => switch (inst.value) {
                .I64 => |int| self.stack_push_i64(i64, int),
                .U64 => |int| self.stack_push_i64(u64, int),
                .F64 => |_| {
                    defer float_counter.* += 1;
                    self.stack_push_f64(float_counter.*);
                },
                .NaN => |nan| switch (nan.getType()) {
                    .I64, .U64 => self.stack_push_i64(i64, nan.as(i64)),
                    .F32, .F64 => {
                        defer float_counter.* += 1;
                        self.stack_push_f64(float_counter.*);
                    },
                    inline else => panic("Unimplemented", .{})
                },
                inline else => panic("Unimplemented", .{})
            },
            .pop => self.wt("sub qword [stack_ptr], WORD_SIZE"),
            .iadd => {
                self.stack_last_two();
                self.wt("add rax, rbx");
                self.stack_mov_to_2nd_from_end_i64("rax");
            },
            .imul => {
                self.stack_last_two();
                self.wt("xor edx, edx");
                self.wt("mul rbx");
                self.stack_mov_to_2nd_from_end_i64("rax");
            },
            .idiv => {
                self.stack_last_two();
                self.wt("xor edx, edx");
                self.wt("idiv rax");
                self.stack_mov_to_2nd_from_end_i64("rax");
            },
            .isub => {
                self.stack_last_two();
                self.wt("sub rbx, rax");
                self.stack_mov_to_2nd_from_end_i64("rbx");
            },
            .fmul => {
                self.stack_last_two_xmm();
                self.binop_f64("mulsd");
            },
            .fdiv => {
                self.stack_last_two_xmm();
                self.binop_f64("divsd");
            },
            .fadd => {
                self.stack_last_two_xmm();
                self.binop_f64("addsd");
            },
            .fsub => {
                self.stack_last_two_xmm();
                self.binop_f64("subsd");
            },
            .dmpln => switch (inst.value.Type) {
                .F64 => {
                    self.stack_last_xmm();
                    self.wt("call dmp_f64");
                },
                .U8, .U64, .I64 => {
                    self.wt("mov r15, qword [stack_ptr]");
                    self.wt("mov rdi, qword [r15 - WORD_SIZE]");
                    self.stack_last();
                    self.wt("call dmp_i64");
                },
                .None => {},
                inline else => panic("Printing type: {} it not implemented yet..", .{inst.value.Type})
            },
            .dec => {
                self.stack_last();
                self.wt("dec rax");
                self.wt("mov [r15 - WORD_SIZE], rax");
            },
            .inc => {
                self.stack_last();
                self.wt("inc rax");
                self.wt("mov [r15 - WORD_SIZE], rax");
            },
            .cmp => switch (inst.value.Type) {
                .F64 => {
                    self.stack_last_two_xmm();
                    self.wt("sub qword [stack_ptr], WORD_SIZE");
                    self.wt("comisd xmm1, xmm0");
                    is_fcmp.* = true;
                },
                .U8, .U64, .I64 => {
                    self.stack_last_two();
                    self.wt("sub qword [stack_ptr], WORD_SIZE");
                    self.wt("cmp rbx, rax");
                    is_fcmp.* = false;
                },
                inline else => panic("Comparing type: {} it not implemented yet..", .{inst.value.Type})
            },
            .swap => {
                const idx = get_u64_idc(inst.value);
                self.stack_last();
                self.wprintt("mov rbx, [r15 - WORD_SIZE - WORD_SIZE * {d}]", .{idx});
                self.wt("mov [r15 - WORD_SIZE], rbx");
                self.wprintt("mov [r15 - WORD_SIZE - WORD_SIZE * {d}], rax", .{idx});
            },
            .dup => {
                const idx = get_u64_idc(inst.value);
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
            .pushmp => {
                self.wt("mov r15, qword [stack_ptr]");
                self.wt("mov r15, [memory_ptr]");
                self.wt("add qword [stack_ptr], WORD_SIZE");
            },
            // NOTE: It works only with integer fds
            .fread => {
                self.stack_last_three();
                self.wt("mov rdi, rdx");
                self.wt("mov rsi, rbx");
                self.wt("mov rdx, rax");
                self.wt("call read_region_into_memory_int_fd");
            },
            .halt => {
                self.wt("mov rax, SYS_EXIT");
                self.wt("xor rdi, rdi");
                self.wt("syscall");
            },
            .ret => self.wprintt("{s}", .{inst.type.to_str()}),
            .call, .jmp, .jnz, .je, .jne => self.wprintt("{s} {s}", .{inst.type.to_str(), inst.value.Str}),
            .label => self.wprint("{s}:", .{inst.value.Str}),
            inline else => panic("{s} is unimplemented yet..", .{inst.type.to_str()})
        }
    }

    pub fn compile2nasm(self: *const Self) !void {
        self.w("BITS 64");
        self.w("%define MEMORY_CAP 8 * 1024");
        self.w("%define STACK_CAP  1024");
        self.w("%define WORD_SIZE  8");
        self.w("%define SYS_WRITE  1");
        self.w("%define SYS_STDOUT 1");
        self.w("%define SYS_EXIT   60");
        self.w("section .text");
        self.w("dmp_i64:");
        self.w("    push    rbp");
        self.w("    mov     rbp, rsp");
        self.w("    sub     rsp, 64");
        self.w("    mov     qword [rbp - 8],  rax");
        self.w("    mov     dword [rbp - 36], 0");
        self.w("    mov     dword [rbp - 40], 0");
        self.w("    cmp     qword [rbp - 8],  0");
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
        self.w("; al:  8bit value");
        self.w("; rdi: start");
        self.w("; rsi: end");
        self.w("write_region:");
        self.w("    mov r15, [memory_ptr]");
        self.w("    add rsi, r15");
        self.w(".loop:");
        self.w("    mov [r15 + rdi], al");
        self.w("    inc r15");
        self.w("    cmp r15, rsi");
        self.w("    jl .loop");
        self.w("    mov qword [memory_ptr], r15");
        self.w("    ret");
        self.w("; rdi: int fd");
        self.w("; rsi: start");
        self.w("; rdx: end");
        self.w("read_region_into_memory_int_fd:");
        self.w("    add rsi, memory_buf");
        self.w("    add rdx, memory_buf");
        self.w("    xor rax, rax");
        self.w("    syscall");
        self.w("    add qword [memory_ptr], rax");
        self.w("    ret");
        self.w("global _start");

        var is_fcmp = false;
        var float_counter: u64 = 0;
        for (self.program) |inst| {
            self.compile_inst2nasm(&inst, &float_counter, &is_fcmp);
        }

        self.w("section .data");
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
        self.w("memory_ptr dq memory_buf");
        self.w("section .bss");
        self.w("memory_buf resb MEMORY_CAP");
        self.w("stack_buf resq STACK_CAP");
    }
};
