const std = @import("std");
const Cpu = @import("lc86K").Cpu;
const isa = @import("isa");

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
    return isa.decodeD9(opcode, val);
}

// ── Suivi de phase BIOS (diagnostic) ──────────────────────
// Anciennement Cpu.checkBiosPhase : sorti du cœur (AD-8). Les PC sont ceux
// du BIOS officiel (vmu_bios_jp.bin) — pure heuristique d'observation,
// aucune sémantique d'exécution.
pub const BiosPhase = enum(u8) {
    none,
    bios_init,
    bios_clear_ram,
    bios_post_init,
    bios_date_wait,
    bios_lcd_setup,
    bios_date_ok,
    bios_main_loop,
    bios_mode_0,
    bios_mode_1,
    bios_mode_2,
    bios_game_launch,
    bios_no_game,
    game_running,
};

var bios_phase: BiosPhase = .none;
var bios_phase_seen: [13]bool = @splat(false);

pub fn checkBiosPhase(cpu: *Cpu) ?BiosPhase {
    if (cpu.inst_bank.bank_id != .rom) {
        if (bios_phase != .game_running) {
            bios_phase = .game_running;
            reportBiosPhase(.game_running, cpu);
            return .game_running;
        }
        return null;
    }
    const new_phase: ?BiosPhase = switch (cpu.pc) {
        0x0200 => .bios_init,
        0x024C => .bios_clear_ram,
        0x0294 => .bios_post_init,
        0x02AF => .bios_date_wait,
        0x02C2 => .bios_lcd_setup,
        0x02EF => .bios_date_ok,
        0x0317 => .bios_main_loop,
        0x033A => .bios_mode_0,
        0x0360 => .bios_mode_1,
        0x0387 => .bios_mode_2,
        0x03AE => .bios_game_launch,
        0x03E1 => .bios_no_game,
        else => null,
    };
    if (new_phase) |phase| {
        if (bios_phase != phase) {
            std.debug.print("PHASE CHANGE: {} -> {} PC={X:0>4} xram_wr={d} vtrbf_wr={d}\n", .{
                bios_phase, phase, cpu.pc, cpu.xram_write_count, cpu.vtrbf_write_count,
            });
            bios_phase = phase;
            const idx = @intFromEnum(phase);
            if (idx < bios_phase_seen.len and !bios_phase_seen[idx]) {
                bios_phase_seen[idx] = true;
                reportBiosPhase(phase, cpu);
                return phase;
            }
        }
    }
    return null;
}

fn reportBiosPhase(phase: BiosPhase, cpu: *Cpu) void {
    std.debug.print("[BIOS] Phase: {s} (PC=0x{X:0>4})\n", .{ @tagName(phase), cpu.pc });
    log("[BIOS] Phase: {s} (PC=0x{X:0>4})", .{ @tagName(phase), cpu.pc });
}

pub fn disassembleAt(cpu: *Cpu, buf: []u8, pc: u16) usize {
    const rom = cpu.inst_bank.data;
    if (pc >= rom.len) return 0;

    const start_pc = pc;
    const opcode = rom[pc];
    const e = isa.entry(opcode);

    // Octets d'opérandes qui suivent l'opcode (bornés par la ROM).
    var ops: [2]u8 = .{ 0, 0 };
    const end: usize = @as(usize, pc) + e.size;
    var p: usize = pc + 1;
    while (p < end and p < rom.len) : (p += 1) {
        ops[p - pc - 1] = rom[p];
    }

    switch (e.disp) {
        .fmtI => return fmtI(buf, start_pc, e.mnemonic),
        .fmtI2 => return fmtI2(buf, start_pc, e.mnemonic, ops[0]),
        .fmtImm, .fmtBI => return fmtImm(buf, start_pc, e.mnemonic, ops[0]),
        .fmtA_d9 => return fmtA(buf, start_pc, e.mnemonic, decodeD9Addr(opcode, ops[0])),
        .fmtR => return fmtR(buf, start_pc, e.mnemonic, @intCast(e.ri.?)),
        .fmtM => return fmtM(buf, start_pc, e.mnemonic, decodeD9Addr(opcode, ops[0]), ops[1]),
        .fmtMR => return fmtMR(buf, start_pc, e.mnemonic, @intCast(e.ri.?), ops[0]),
        .fmtBitBranch => return fmtBitBranch(buf, start_pc, e.mnemonic, decodeD9Addr(opcode, ops[0]), @intCast(e.bit.?)),
        .fmtBitOp => return fmtBitOp(buf, start_pc, e.mnemonic, decodeD9Addr(opcode, ops[0]), @intCast(e.bit.?)),
        .fmtA_br => {
            const tgt: u16 = start_pc + 2 +% @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(ops[0])))));
            return fmtA(buf, start_pc, e.mnemonic, tgt);
        },
        .fmtA_callr => {
            const offset = (@as(u16, ops[1]) << 8) | @as(u16, ops[0]);
            const tgt: u16 = start_pc +% 3 +% @as(u16, @bitCast(@as(i16, @bitCast(offset))));
            return fmtA(buf, start_pc, e.mnemonic, tgt);
        },
        .fmtA_jmp => {
            const ad12 = ((@as(u16, opcode & 0x10) << 7) |
                (@as(u16, opcode & 0x07) << 8) |
                @as(u16, ops[0]));
            return fmtA(buf, start_pc, e.mnemonic, (start_pc & 0xF000) | ad12);
        },
        .fmtA_abs => return fmtA(buf, start_pc, e.mnemonic, (@as(u16, ops[1]) << 8) | @as(u16, ops[0])),
    }
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
        cpu.sfr_raw[Cpu.SFR_IE],
        if (cpu.halted) "YES" else "no",
        cpu.interrupt_depth,
    }) catch return buf.len;
    return msg.len;
}

pub fn formatSfrState(cpu: *Cpu, buf: []u8) usize {
    const msg = std.fmt.bufPrint(buf, "T0CNT={X:0>2} T0L={X:0>2} T0H={X:0>2} T1CNT={X:0>2} T1L={X:0>2} T1H={X:0>2} BTCR={X:0>2} P3={X:0>2}", .{
        cpu.sfr_raw[Cpu.SFR_P3INT],
        cpu.t0l_counter,
        cpu.t0h_counter,
        cpu.sfr_raw[Cpu.SFR_T1CNT],
        cpu.t1l_counter,
        cpu.t1h_counter,
        cpu.sfr_raw[Cpu.SFR_BTCR],
        cpu.p3_buttons,
    }) catch return buf.len;
    return msg.len;
}

pub fn instSize(rom: []const u8, addr: u16) u16 {
    if (addr >= rom.len) return 1;
    return isa.TABLE[rom[addr]].size;
}
