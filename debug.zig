const std = @import("std");
const Cpu = @import("lc86K").Cpu;

pub const LogLevel = enum(u8) {
    none = 0,
    error_level = 1,
    warn = 2,
    info = 3,
    trace = 4,
};

pub var log_level: LogLevel = .info;

pub const LOG_LINES: usize = 64;
pub var log_ring: [LOG_LINES][256]u8 = undefined;
pub var log_ring_len: [LOG_LINES]usize = @splat(0);
pub var log_ring_pos: usize = 0;
pub var log_ring_count: usize = 0;

pub const FILE_BUF_SIZE: usize = 1024 * 1024;
pub var file_buf: [FILE_BUF_SIZE]u8 = undefined;
pub var file_buf_pos: usize = 0;
pub var file_enabled: bool = false;
pub var halt_sample: u16 = 0;

pub fn init() void {
    log_ring_pos = 0;
    log_ring_count = 0;
    file_buf_pos = 0;
    file_enabled = false;
}

pub fn enableFileLog() void {
    file_enabled = true;
    file_buf_pos = 0;
}

pub fn disableFileLog() void {
    file_enabled = false;
}

pub fn getLogData() []const u8 {
    return file_buf[0..file_buf_pos];
}

pub fn clearLogData() void {
    file_buf_pos = 0;
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(log_level) == 0 and !file_enabled) return;

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;

    if (@intFromEnum(log_level) < @intFromEnum(LogLevel.trace)) {
        std.debug.print("{s}\n", .{msg});
    }

    if (@intFromEnum(log_level) != 0) {
        const len = @min(msg.len, 255);
        @memcpy(log_ring[log_ring_pos][0..len], msg[0..len]);
        log_ring_len[log_ring_pos] = len;
        log_ring_pos = (log_ring_pos + 1) % LOG_LINES;
        if (log_ring_count < LOG_LINES) log_ring_count += 1;
    }

    if (file_enabled and file_buf_pos + msg.len + 1 <= FILE_BUF_SIZE) {
        @memcpy(file_buf[file_buf_pos .. file_buf_pos + msg.len], msg);
        file_buf_pos += msg.len;
        file_buf[file_buf_pos] = '\n';
        file_buf_pos += 1;
    }
}

pub fn logLine(line: []const u8) void {
    if (@intFromEnum(log_level) == 0 and !file_enabled) return;

    if (@intFromEnum(log_level) != 0) {
        const len = @min(line.len, 255);
        @memcpy(log_ring[log_ring_pos][0..len], line[0..len]);
        log_ring_len[log_ring_pos] = len;
        log_ring_pos = (log_ring_pos + 1) % LOG_LINES;
        if (log_ring_count < LOG_LINES) log_ring_count += 1;
    }

    if (file_enabled and file_buf_pos + line.len + 1 <= FILE_BUF_SIZE) {
        @memcpy(file_buf[file_buf_pos .. file_buf_pos + line.len], line);
        file_buf_pos += line.len;
        file_buf[file_buf_pos] = '\n';
        file_buf_pos += 1;
    }
}

pub fn getRingLine(idx: usize) ?[]const u8 {
    if (idx >= log_ring_count) return null;
    const actual = if (log_ring_count >= LOG_LINES)
        (log_ring_pos + LOG_LINES - log_ring_count + idx) % LOG_LINES
    else
        idx;
    const len = log_ring_len[actual];
    if (len == 0) return null;
    return log_ring[actual][0..len];
}

fn decodeD9Addr(opcode: u8, val: u8) u16 {
    const d8: u16 = if (opcode & 0x08 != 0)
        @as(u16, opcode >> 4) & 1
    else
        @as(u16, opcode) & 1;
    return d8 << 8 | val;
}

pub fn disassembleAt(cpu: *Cpu, buf: []u8, pc: u16) usize {
    const rom = cpu.inst_bank.data;
    if (pc >= rom.len) return 0;

    const start_pc = pc;
    var p: usize = pc;
    const opcode = rom[p];
    p += 1;

    const row: u4 = @truncate(opcode >> 4);
    const col: u4 = @truncate(opcode);

    switch (row) {
        0x0 => switch (col) {
            0x0 => return fmtI(buf, start_pc, "NOP"),
            0x1 => {
                const r8 = rom[p];
                const tgt: u16 = start_pc + 2 +% @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(r8)))));
                return fmtA(buf, start_pc, "BR", tgt);
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "LD", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "LD", ri);
            },
            0x8...0xF => {
                const imm8 = rom[p];
                const ad12 = ((@as(u16, opcode & 0x10) << 7) |
                    (@as(u16, opcode & 0x07) << 8) |
                    @as(u16, imm8));
                const target = (start_pc & 0xF000) | ad12;
                return fmtA(buf, start_pc, "CALL", target);
            },
        },
        0x1 => switch (col) {
            0x0 => {
                const lo = rom[p];
                const hi = rom[p + 1];
                const offset = (@as(u16, hi) << 8) | @as(u16, lo);
                const tgt: u16 = start_pc +% 3 +% @as(u16, @bitCast(@as(i16, @bitCast(offset))));
                return fmtA(buf, start_pc, "CALLR", tgt);
            },
            0x1 => {
                const r8 = rom[p];
                return fmtI2(buf, start_pc, "BRF", r8);
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "ST", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "ST", ri);
            },
            0x8...0xF => {
                const imm8 = rom[p];
                const ad12 = ((@as(u16, opcode & 0x10) << 7) |
                    (@as(u16, opcode & 0x07) << 8) |
                    @as(u16, imm8));
                const target = (start_pc & 0xF000) | ad12;
                return fmtA(buf, start_pc, "CALL", target);
            },
        },
        0x2 => switch (col) {
            0x0 => {
                const hi = rom[p];
                const lo = rom[p + 1];
                return fmtA(buf, start_pc, "CALLF", (@as(u16, hi) << 8) | @as(u16, lo));
            },
            0x1 => {
                const hi = rom[p];
                const lo = rom[p + 1];
                return fmtA(buf, start_pc, "JMPF", (@as(u16, hi) << 8) | @as(u16, lo));
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                const imm = rom[p + 1];
                return fmtM(buf, start_pc, "MOV", decodeD9Addr(opcode, d8), imm);
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                const imm = rom[p];
                return fmtMR(buf, start_pc, "MOV", ri, imm);
            },
            0x8...0xF => {
                const imm8 = rom[p];
                const ad12 = ((@as(u16, opcode & 0x10) << 7) |
                    (@as(u16, opcode & 0x07) << 8) |
                    @as(u16, imm8));
                return fmtA(buf, start_pc, "JMP", (start_pc & 0xF000) | ad12);
            },
        },
        0x3 => switch (col) {
            0x0 => return fmtI(buf, start_pc, "MUL"),
            0x1 => {
                const imm = rom[p];
                return fmtBI(buf, start_pc, "BE", imm);
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                const r8 = rom[p + 1];
                _ = r8;
                return fmtA(buf, start_pc, "BE", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "BE", ri);
            },
            0x8...0xF => {
                const imm8 = rom[p];
                const ad12 = ((@as(u16, opcode & 0x10) << 7) |
                    (@as(u16, opcode & 0x07) << 8) |
                    @as(u16, imm8));
                return fmtA(buf, start_pc, "JMP", (start_pc & 0xF000) | ad12);
            },
        },
        0x4 => switch (col) {
            0x0 => return fmtI(buf, start_pc, "DIV"),
            0x1 => {
                const imm = rom[p];
                return fmtBI(buf, start_pc, "BNE", imm);
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                _ = rom[p + 1];
                return fmtA(buf, start_pc, "BNE", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "BNE", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBPC(buf, start_pc, "BPC", decodeD9Addr(opcode, d8), bit);
            },
        },
        0x5 => switch (col) {
            0x0, 0x1 => return fmtI(buf, start_pc, "NOP"),
            0x2, 0x3 => {
                const d8 = rom[p];
                _ = rom[p + 1];
                return fmtA(buf, start_pc, "DBNZ", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "DBNZ", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBPC(buf, start_pc, "BPC", decodeD9Addr(opcode, d8), bit);
            },
        },
        0x6 => switch (col) {
            0x0, 0x1 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "PUSH", decodeD9Addr(opcode, d8));
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "INC", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "INC", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBitBranch(buf, start_pc, "BP", decodeD9Addr(opcode, d8), bit);
            },
        },
        0x7 => switch (col) {
            0x0, 0x1 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "POP", decodeD9Addr(opcode, d8));
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "DEC", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "DEC", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBitBranch(buf, start_pc, "BP", decodeD9Addr(opcode, d8), bit);
            },
        },
        0x8 => switch (col) {
            0x0 => {
                return fmtI(buf, start_pc, "BZ");
            },
            0x1 => {
                const imm = rom[p];
                return fmtImm(buf, start_pc, "ADD", imm);
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "ADD", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "ADD", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBitBranch(buf, start_pc, "BN", decodeD9Addr(opcode, d8), bit);
            },
        },
        0x9 => switch (col) {
            0x0 => return fmtI(buf, start_pc, "BNZ"),
            0x1 => {
                const imm = rom[p];
                return fmtImm(buf, start_pc, "ADDC", imm);
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "ADDC", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "ADDC", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBitBranch(buf, start_pc, "BN", decodeD9Addr(opcode, d8), bit);
            },
        },
        0xA => switch (col) {
            0x0 => return fmtI(buf, start_pc, "RET"),
            0x1 => {
                const imm = rom[p];
                return fmtImm(buf, start_pc, "SUB", imm);
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "SUB", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "SUB", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBitOp(buf, start_pc, "NOT1", decodeD9Addr(opcode, d8), bit);
            },
        },
        0xB => switch (col) {
            0x0 => return fmtI(buf, start_pc, "RETI"),
            0x1 => {
                const imm = rom[p];
                return fmtImm(buf, start_pc, "SUBC", imm);
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "SUBC", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "SUBC", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBitOp(buf, start_pc, "NOT1", decodeD9Addr(opcode, d8), bit);
            },
        },
        0xC => switch (col) {
            0x0 => return fmtI(buf, start_pc, "ROR"),
            0x1 => return fmtI(buf, start_pc, "LDC"),
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "XCH", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "XCH", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBitOp(buf, start_pc, "CLR1", decodeD9Addr(opcode, d8), bit);
            },
        },
        0xD => switch (col) {
            0x0 => return fmtI(buf, start_pc, "RORC"),
            0x1 => {
                const imm = rom[p];
                return fmtImm(buf, start_pc, "OR", imm);
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "OR", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "OR", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBitOp(buf, start_pc, "CLR1", decodeD9Addr(opcode, d8), bit);
            },
        },
        0xE => switch (col) {
            0x0 => return fmtI(buf, start_pc, "ROL"),
            0x1 => {
                const imm = rom[p];
                return fmtImm(buf, start_pc, "AND", imm);
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "AND", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "AND", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBitOp(buf, start_pc, "SET1", decodeD9Addr(opcode, d8), bit);
            },
        },
        0xF => switch (col) {
            0x0 => return fmtI(buf, start_pc, "ROLC"),
            0x1 => {
                const imm = rom[p];
                return fmtImm(buf, start_pc, "XOR", imm);
            },
            0x2, 0x3 => {
                const d8 = rom[p];
                return fmtA(buf, start_pc, "XOR", decodeD9Addr(opcode, d8));
            },
            0x4...0x7 => {
                const ri: u2 = @intCast(col & 0x3);
                return fmtR(buf, start_pc, "XOR", ri);
            },
            0x8...0xF => {
                const d8 = rom[p];
                const bit: u3 = @intCast(opcode & 0x07);
                return fmtBitOp(buf, start_pc, "SET1", decodeD9Addr(opcode, d8), bit);
            },
        },
    }
    return 0;
}

fn fmtI(buf: []u8, pc: u16, mnem: []const u8) usize {
    return (std.fmt.bufPrint(buf, "{X:0>4}: {s}", .{ pc, mnem }) catch return 0).len;
}

fn fmtI2(buf: []u8, pc: u16, mnem: []const u8, val: anytype) usize {
    return (std.fmt.bufPrint(buf, "{X:0>4}: {s} {X:0>4}", .{ pc, mnem, @as(u16, val) }) catch return 0).len;
}

fn fmtImm(buf: []u8, pc: u16, mnem: []const u8, imm: u8) usize {
    return (std.fmt.bufPrint(buf, "{X:0>4}: {s} #{X:0>2}h", .{ pc, mnem, imm }) catch return 0).len;
}

fn fmtA(buf: []u8, pc: u16, mnem: []const u8, addr: u16) usize {
    return (std.fmt.bufPrint(buf, "{X:0>4}: {s} {X:0>4}h", .{ pc, mnem, addr }) catch return 0).len;
}

fn fmtR(buf: []u8, pc: u16, mnem: []const u8, ri: u2) usize {
    return (std.fmt.bufPrint(buf, "{X:0>4}: {s} @R{d}", .{ pc, mnem, ri }) catch return 0).len;
}

fn fmtM(buf: []u8, pc: u16, mnem: []const u8, addr: u16, imm: u8) usize {
    return (std.fmt.bufPrint(buf, "{X:0>4}: {s} {X:0>4}h,#{X:0>2}h", .{ pc, mnem, addr, imm }) catch return 0).len;
}

fn fmtMR(buf: []u8, pc: u16, mnem: []const u8, ri: u2, imm: u8) usize {
    return (std.fmt.bufPrint(buf, "{X:0>4}: {s} @R{d},#{X:0>2}h", .{ pc, mnem, ri, imm }) catch return 0).len;
}

fn fmtBI(buf: []u8, pc: u16, mnem: []const u8, imm: u8) usize {
    return (std.fmt.bufPrint(buf, "{X:0>4}: {s} #{X:0>2}h", .{ pc, mnem, imm }) catch return 0).len;
}

fn fmtBPC(buf: []u8, pc: u16, mnem: []const u8, addr: u16, bit: u3) usize {
    return (std.fmt.bufPrint(buf, "{X:0>4}: {s} {X:0>3}h.{d}", .{ pc, mnem, addr, bit }) catch return 0).len;
}

fn fmtBitBranch(buf: []u8, pc: u16, mnem: []const u8, addr: u16, bit: u3) usize {
    return (std.fmt.bufPrint(buf, "{X:0>4}: {s} {X:0>3}h.{d}", .{ pc, mnem, addr, bit }) catch return 0).len;
}

fn fmtBitOp(buf: []u8, pc: u16, mnem: []const u8, addr: u16, bit: u3) usize {
    return (std.fmt.bufPrint(buf, "{X:0>4}: {s} {X:0>3}h.{d}", .{ pc, mnem, addr, bit }) catch return 0).len;
}

// ── Loop detection ────────────────────────────────────────
const LOOP_WINDOW: usize = 128;
pub var pc_history: [LOOP_WINDOW]u16 = undefined;
pub var pc_hist_pos: usize = 0;
pub var loop_detected_pc: ?u16 = null;
pub var loop_count: u32 = 0;

pub fn recordPC(pc: u16) void {
    pc_history[pc_hist_pos] = pc;
    pc_hist_pos = (pc_hist_pos + 1) % LOOP_WINDOW;

    var same_count: u32 = 0;
    for (pc_history) |h| {
        if (h == pc) same_count += 1;
    }
    if (same_count > LOOP_WINDOW * 2 / 3) {
        if (loop_detected_pc) |lp| {
            if (lp == pc) {
                loop_count += 1;
            } else {
                loop_detected_pc = pc;
                loop_count = 1;
            }
        } else {
            loop_detected_pc = pc;
            loop_count = 1;
        }
    } else if (loop_detected_pc) |lp| {
        if (lp != pc) {
            loop_detected_pc = null;
            loop_count = 0;
        }
    }
}

pub fn formatCpuState(cpu: *Cpu, buf: []u8) usize {
    const msg = std.fmt.bufPrint(buf, "A={X:0>2} B={X:0>2} C={X:0>2} SP={X:0>2} PSW={X:0>2} IE={X:0>2} halted={s} depth={d}", .{
        cpu.a,
        cpu.b,
        cpu.c,
        cpu.sp,
        @as(u8, @bitCast(cpu.psw)),
        cpu.sfr_raw[0x08],
        if (cpu.halted) "YES" else "no",
        cpu.interrupt_depth,
    }) catch return buf.len;
    return msg.len;
}

pub fn formatSfrState(cpu: *Cpu, buf: []u8) usize {
    const msg = std.fmt.bufPrint(buf, "T0CNT={X:0>2} T0L={X:0>2} T0H={X:0>2} T1CNT={X:0>2} T1L={X:0>2} T1H={X:0>2} BTCR={X:0>2} P3={X:0>2}", .{
        cpu.sfr_raw[0x4E],
        cpu.t0l_counter,
        cpu.t0h_counter,
        cpu.sfr_raw[0x18],
        cpu.t1l_counter,
        cpu.t1h_counter,
        cpu.sfr_raw[0x7F],
        cpu.p3_buttons,
    }) catch return buf.len;
    return msg.len;
}

pub fn instSize(rom: []const u8, addr: u16) u16 {
    if (addr >= rom.len) return 1;
    const opcode = rom[addr];
    const row: u4 = @truncate(opcode >> 4);
    const col: u4 = @truncate(opcode);

    return switch (row) {
        0x0 => switch (col) {
            0x0 => 1, 0x1 => 2, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 2,
        },
        0x1 => switch (col) {
            0x0 => 3, 0x1 => 2, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 2,
        },
        0x2 => switch (col) {
            0x0, 0x1 => 3, 0x2, 0x3 => 3, 0x4...0x7 => 2, 0x8...0xF => 2,
        },
        0x3 => switch (col) {
            0x0 => 1, 0x1, 0x2, 0x3 => 3, 0x4...0x7 => 2, 0x8...0xF => 2,
        },
        0x4 => switch (col) {
            0x0 => 1, 0x1, 0x2, 0x3 => 3, 0x4...0x7 => 2, 0x8...0xF => 3,
        },
        0x5 => switch (col) {
            0x0, 0x1 => 1, 0x2, 0x3 => 3, 0x4...0x7 => 2, 0x8...0xF => 3,
        },
        0x6 => switch (col) {
            0x0, 0x1 => 2, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 3,
        },
        0x7 => switch (col) {
            0x0, 0x1 => 2, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 3,
        },
        0x8 => switch (col) {
            0x0 => 2, 0x1, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 3,
        },
        0x9 => switch (col) {
            0x0 => 2, 0x1, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 3,
        },
        0xA => switch (col) {
            0x0 => 1, 0x1, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 2,
        },
        0xB => switch (col) {
            0x0 => 1, 0x1, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 2,
        },
        0xC => switch (col) {
            0x0, 0x1 => 1, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 2,
        },
        0xD => switch (col) {
            0x0 => 1, 0x1, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 2,
        },
        0xE => switch (col) {
            0x0 => 1, 0x1, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 2,
        },
        0xF => switch (col) {
            0x0 => 1, 0x1, 0x2, 0x3 => 2, 0x4...0x7 => 1, 0x8...0xF => 2,
        },
    };
}
