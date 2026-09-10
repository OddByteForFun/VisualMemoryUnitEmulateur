const std = @import("std");
const Cpu = @import("lc86K").Cpu;
const dbg = @import("debug");
const isa = @import("isa");

// https://mc.pp.se/dc/vms/cpu.html
// L'encodage des opcodes, Inst et AddressingMode viennent d'isa.zig (source unique).

pub const DecodeResult = isa.IsaEntry;

fn decodeOpcode(opcode: u8) DecodeResult {
    return isa.TABLE[opcode];
}

fn cycles(dec: DecodeResult) u8 {
    return dec.cycles;
}

pub fn step(cpu: *Cpu) u8 {
    if (cpu.halted) {
        const old_p3 = cpu.p3_buttons;
        cpu.tickTimers(1);
        cpu.requestLevelDrivenInterrupts();
        cpu.servicePendingInterrupt();

        if (cpu.halted and cpu.p3_buttons != old_p3) {
            if (dbg.log_level == .trace) {
                dbg.log("P3 WAKEUP: P3={X:0>2}->{X:0>2} PC={X:0>4} P3INT={X:0>2}", .{
                    old_p3, cpu.p3_buttons, cpu.pc, cpu.sfr_raw[0x4E],
                });
            }
            cpu.halted = false;
        }

        if (cpu.p3_buttons != old_p3 or dbg.halt_sample == 0) {
            if (dbg.log_level == .trace) {
                const p3int = cpu.sfr_raw[0x4E];
                dbg.log("HALT PC={X:0>4} P3={X:0>2}->{X:0>2} P3INT={X:0>2} IE={X:0>2} depth={d} blocked={d} halted={}", .{
                    cpu.pc,
                    old_p3,
                    cpu.p3_buttons,
                    p3int,
                    cpu.sfr_raw[0x08],
                    cpu.interrupt_depth,
                    cpu.interrupt_blocked,
                    cpu.halted,
                });
            }
        }
        dbg.halt_sample +%= 1;
        if (dbg.halt_sample >= 10000) dbg.halt_sample = 0;
        return 1;
    }

    dbg.recordPC(cpu.pc);

    const pc_before = cpu.pc;
    const opcode = cpu.fetch8();
    const dec = decodeOpcode(opcode);

    if (dbg.log_level == .trace) {
        var buf: [64]u8 = undefined;
        const len = dbg.disassembleAt(cpu, &buf, pc_before);
        if (len > 0) {
            dbg.log("{s}  A={X:0>2} B={X:0>2} C={X:0>2} SP={X:0>2} PSW={X:0>2}", .{ buf[0..len], cpu.a, cpu.b, cpu.c, cpu.sp, @as(u8, @bitCast(cpu.psw)) });
        }
    }

    switch (dec.inst) {
        .nop => {},
        .br => {
            const rel: u16 = @bitCast(@as(i16, @as(i8, @bitCast(cpu.fetch8()))));
            cpu.pc +%= rel;
        },
        .brf => {
            const r16 = cpu.fetch16();
            cpu.pc +%= r16 -% 1;
        },
        .bz => {
            const offset = cpu.fetch8();
            if (cpu.a == 0) cpu.pc +%= signExt8(offset);
        },
        .bnz => {
            const offset = cpu.fetch8();
            if (cpu.a != 0) cpu.pc +%= signExt8(offset);
        },

        .add_imm, .add_d9, .add_ri => {
            const v = readOp8(cpu, dec);
            const result: u16 = @as(u16, cpu.a) + @as(u16, v);
            cpu.psw.cy = result > 0xFF;
            cpu.psw.ac = (cpu.a & 0xF) + (v & 0xF) > 0xF;
            cpu.psw.ov = (@as(u1, @truncate(cpu.a >> 7)) == @as(u1, @truncate(v >> 7))) and
                (@as(u1, @truncate(cpu.a >> 7)) != @as(u1, @truncate(result >> 7)));
            cpu.a = @truncate(result);
            cpu.psw.p = @popCount(cpu.a) % 2 == 1;
        },
        .addc_imm, .addc_d9, .addc_ri => {
            const v = readOp8(cpu, dec);
            const old_cy: u4 = @intFromBool(cpu.psw.cy);
            const result: u16 = @as(u16, cpu.a) + @as(u16, v) + old_cy;
            cpu.psw.cy = result > 0xFF;
            cpu.psw.ac = (cpu.a & 0xF) + (v & 0xF) + old_cy > 0xF;
            cpu.psw.ov = (@as(u1, @truncate(cpu.a >> 7)) == @as(u1, @truncate(v >> 7))) and
                (@as(u1, @truncate(cpu.a >> 7)) != @as(u1, @truncate(result >> 7)));
            cpu.a = @truncate(result);
            cpu.psw.p = @popCount(cpu.a) % 2 == 1;
        },
        .sub_imm, .sub_d9, .sub_ri => {
            const v = readOp8(cpu, dec);
            const result: i16 = @as(i16, cpu.a) - @as(i16, v);
            const r_u8: u8 = @truncate(@as(u16, @bitCast(result)));
            const sa: u1 = @truncate(cpu.a >> 7);
            const sv: u1 = @truncate(v >> 7);
            const sr: u1 = @truncate(r_u8 >> 7);
            cpu.psw.cy = result < 0;
            cpu.psw.ac = (cpu.a & 0xF) < (v & 0xF);
            cpu.psw.ov = (sa != sv) and (sa != sr);
            cpu.a = r_u8;
            cpu.psw.p = @popCount(cpu.a) % 2 == 1;
        },
        .subc_imm, .subc_d9, .subc_ri => {
            const v = readOp8(cpu, dec);
            const old_cy: i16 = @intFromBool(cpu.psw.cy);
            const result: i16 = @as(i16, cpu.a) - @as(i16, v) - old_cy;
            const r_u8: u8 = @truncate(@as(u16, @bitCast(result)));
            const sa: u1 = @truncate(cpu.a >> 7);
            const sv: u1 = @truncate(v >> 7);
            const sr: u1 = @truncate(r_u8 >> 7);
            cpu.psw.cy = result < 0;
            cpu.psw.ac = (cpu.a & 0xF) < (v & 0xF) + @as(u4, @truncate(@as(u8, @intCast(old_cy))));
            cpu.psw.ov = (sa != sv) and (sa != sr);
            cpu.a = r_u8;
            cpu.psw.p = @popCount(cpu.a) % 2 == 1;
        },
        .and_imm, .and_d9, .and_ri => {
            cpu.a &= readOp8(cpu, dec);
            cpu.psw.p = @popCount(cpu.a) % 2 == 1;
        },
        .or_imm, .or_d9, .or_ri => {
            cpu.a |= readOp8(cpu, dec);
            cpu.psw.p = @popCount(cpu.a) % 2 == 1;
        },
        .xor_imm, .xor_d9, .xor_ri => {
            cpu.a ^= readOp8(cpu, dec);
            cpu.psw.p = @popCount(cpu.a) % 2 == 1;
        },

        .inc_d9, .inc_ri => {
            const addr = readEA(cpu, dec);
            const val = cpu.load8(addr) +% 1;
            cpu.store8(addr, val);
            cpu.psw.p = @popCount(val) % 2 == 1;
        },
        .dec_d9, .dec_ri => {
            const addr = readEA(cpu, dec);
            const val = cpu.load8(addr) -% 1;
            cpu.store8(addr, val);
            cpu.psw.p = @popCount(val) % 2 == 1;
        },

        .ld => {
            const addr = readEA(cpu, dec);
            cpu.a = cpu.load8(addr);
            if (addr == 0x14C and cpu.p3_buttons != 0xFF and dbg.log_level == .trace) {
                dbg.log("LD P3 -> {X:0>2} (PC={X:0>4})", .{ cpu.p3_buttons, cpu.pc - 2 });
            }
        },
        .ld_ri => {
            const addr = readIndirectAddr(cpu, @as(u2, @intCast(dec.ri.?)));
            cpu.a = cpu.load8(addr);
        },
        .st => {
            const addr = readEA(cpu, dec);
            cpu.store8(addr, cpu.a);
        },
        .st_ri => {
            const addr = readIndirectAddr(cpu, @as(u2, @intCast(dec.ri.?)));
            cpu.store8(addr, cpu.a);
        },

        .push => {
            const addr = readEA(cpu, dec);
            const val = cpu.load8(addr);
            cpu.sp +%= 1;
            cpu.ram_bank0[cpu.sp] = val;
        },
        .pop => {
            const addr = readEA(cpu, dec);
            const val = cpu.ram_bank0[cpu.sp];
            cpu.sp -%= 1;
            cpu.store8(addr, val);
        },

        .xch_d9, .xch_ri => {
            const addr = readEA(cpu, dec);
            const tmp = cpu.load8(addr);
            cpu.store8(addr, cpu.a);
            cpu.a = tmp;
        },

        .mul => {
            // (B) (ACC) (C) <- (ACC) (C) * (B)
            const operand: u16 = (@as(u16, cpu.a) << 8) | @as(u16, cpu.c);
            const result: u24 = @as(u24, operand) * @as(u24, cpu.b);
            cpu.b = @truncate(result >> 16);
            cpu.a = @truncate(result >> 8);
            cpu.c = @truncate(result);
            cpu.psw.cy = false;
            cpu.psw.ov = result > 0xFFFF;
        },
        .div => {
            // (ACC) (C), mod(B) <- (ACC) (C) / (B)
            if (cpu.b == 0) {
                cpu.a = 0xFF;
                cpu.psw.ov = true;
            } else {
                const operand: u16 = (@as(u16, cpu.a) << 8) | @as(u16, cpu.c);
                const result: u16 = operand / @as(u16, cpu.b);
                const mod: u16 = operand % @as(u16, cpu.b);
                cpu.a = @truncate(result >> 8);
                cpu.c = @truncate(result);
                cpu.b = @truncate(mod);
                cpu.psw.ov = false;
            }
            cpu.psw.cy = false;
        },
        .ror => {
            cpu.psw.cy = (cpu.a & 1) == 1;
            cpu.a = (cpu.a >> 1) | ((cpu.a & 1) << 7);
        },
        .rol => {
            cpu.psw.cy = (cpu.a >> 7) == 1;
            cpu.a = (cpu.a << 1) | (cpu.a >> 7);
        },
        .rorc => {
            const old_c = @as(u8, @intFromBool(cpu.psw.cy));
            cpu.psw.cy = (cpu.a & 1) == 1;
            cpu.a = (old_c << 7) | (cpu.a >> 1);
        },
        .rolc => {
            const old_c = @as(u8, @intFromBool(cpu.psw.cy));
            cpu.psw.cy = (cpu.a >> 7) == 1;
            cpu.a = (cpu.a << 1) | old_c;
        },
        .bn => {
            const addr = readEA(cpu, dec);
            const bit = @as(u3, @intCast(dec.bit.?));
            const r8 = cpu.fetch8();
            const val = cpu.load8(addr);
            if ((val >> bit) & 1 == 0)
                cpu.pc +%= signExt8(r8);
        },
        .bp => {
            const addr = readEA(cpu, dec);
            const bit = @as(u3, @intCast(dec.bit.?));
            const r8 = cpu.fetch8();
            const val = cpu.load8(addr);
            if ((val >> bit) & 1 != 0)
                cpu.pc +%= signExt8(r8);
        },
        .call_a12 => {
            const imm8 = cpu.fetch8();
            const return_addr = cpu.pc;
            cpu.sp +%= 1;
            cpu.ram_bank0[cpu.sp] = @truncate(return_addr & 0xFF);
            cpu.sp +%= 1;
            cpu.ram_bank0[cpu.sp] = @truncate(return_addr >> 8);
            const ad12 = ((@as(u16, dec.opcode & 0x10) << 7) |
                (@as(u16, dec.opcode & 0x07) << 8) |
                @as(u16, imm8));
            cpu.pc = (cpu.pc & 0xF000) | ad12;
        },
        .callr => {
            const lo = cpu.fetch8();
            const hi = cpu.fetch8();
            const offset = @as(u16, hi) << 8 | @as(u16, lo);
            const return_addr = cpu.pc;
            cpu.sp +%= 1;
            cpu.ram_bank0[cpu.sp] = @truncate(return_addr & 0xFF);
            cpu.sp +%= 1;
            cpu.ram_bank0[cpu.sp] = @truncate(return_addr >> 8);
            cpu.pc = return_addr +% offset -% 1;
        },
        .mov => {
            const addr = readEA(cpu, dec);
            const imm8 = cpu.fetch8();
            cpu.store8(addr, imm8);
        },
        .mov_ri => {
            const addr = readIndirectAddr(cpu, @as(u2, @intCast(dec.ri.?)));
            const imm8 = cpu.fetch8();
            cpu.store8(addr, imm8);
        },
        .be_imm, .be_d9, .be_ri => {
            const val = readOp8(cpu, dec);
            const r8 = cpu.fetch8();
            cpu.psw.cy = cpu.a < val;
            if (cpu.a == val) cpu.pc +%= signExt8(r8);
        },
        .bne_imm, .bne_d9, .bne_ri => {
            const val = readOp8(cpu, dec);
            const r8 = cpu.fetch8();
            cpu.psw.cy = cpu.a < val;
            if (cpu.a != val) cpu.pc +%= signExt8(r8);
        },
        .set1, .clr1, .not1 => {
            const addr = readEA(cpu, dec);
            const bit = @as(u3, @intCast(dec.bit.?));
            const old = cpu.load8(addr);
            const new = switch (dec.inst) {
                .set1 => old | (@as(u8, 1) << bit),
                .clr1 => old & ~(@as(u8, 1) << bit),
                .not1 => old ^ (@as(u8, 1) << bit),
                else => unreachable,
            };
            cpu.store8(addr, new);
        },
        .callf => {
            const hi = cpu.fetch8();
            const lo = cpu.fetch8();
            const return_addr = cpu.pc;
            cpu.sp +%= 1;
            cpu.ram_bank0[cpu.sp] = @truncate(return_addr & 0xFF);
            cpu.sp +%= 1;
            cpu.ram_bank0[cpu.sp] = @truncate(return_addr >> 8);
            const target = (@as(u16, hi) << 8) | @as(u16, lo);
            cpu.pc = target;
        },
        .jmpf => {
            const hi = cpu.fetch8();
            const lo = cpu.fetch8();
            cpu.pc = (@as(u16, hi) << 8) | @as(u16, lo);
            cpu.syncInstructionBank(); // bank switch différé : commit le switch ici
        },
        .ret => {
            const hi = cpu.ram_bank0[cpu.sp];
            cpu.sp -%= 1;
            const lo = cpu.ram_bank0[cpu.sp];
            cpu.sp -%= 1;
            cpu.pc = (@as(u16, hi) << 8) | @as(u16, lo);
        },
        .ldc => {
            // (ACC) ← (BNK)((TRR) + (ACC)) [ROM]
            const trr = (@as(u16, cpu.trh) << 8) | cpu.trl;
            cpu.a = cpu.inst_bank.data[trr +% cpu.a];
        },
        .ldf => {
            cpu.a = cpu.readFlash();
        },
        .stf => {
            cpu.writeFlash(cpu.a);
        },
        .jmp_a12 => {
            const imm8 = cpu.fetch8();
            const ad12 = ((@as(u16, dec.opcode & 0x10) << 7) |
                (@as(u16, dec.opcode & 0x07) << 8) |
                @as(u16, imm8));
            cpu.pc = (cpu.pc & 0xF000) | ad12;
        },
        .reti => {
            const hi = cpu.ram_bank0[cpu.sp];
            cpu.sp -%= 1;
            const lo = cpu.ram_bank0[cpu.sp];
            cpu.sp -%= 1;
            cpu.pc = (@as(u16, hi) << 8) | @as(u16, lo);
            // Restaurer le bank d'instructions pré-interruption (sauvegardé par servicePendingInterrupt)
            cpu.pending_ext = cpu.saved_pending_ext;
            cpu.syncInstructionBank();
            if (dbg.log_level == .trace) {
                dbg.log("RETI -> PC={X:0>4} depth_before={d}", .{ cpu.pc, cpu.interrupt_depth });
            }
            cpu.interrupt_depth = 0;
            cpu.process_this_instr = false; // skip PIC dispatch for 1 instruction
        },
        .dbnz_d9, .dbnz_ri => {
            //(PC) ← (PC) + 3, (d9) = (d9)-1, if (d9) ≠ 0 then (PC) ← (PC) + r8
            // (PC) ← (PC) + 2, ((Rj)) = ((Rj)) - 1, if ((Rj)) π 0 then (PC) ← (PC) + r8 j = 0, 1, 2, 3
            const addr = readEA(cpu, dec);
            const val = cpu.load8(addr) -% 1;
            cpu.store8(addr, val);
            const r8 = cpu.fetch8();
            if (val != 0) cpu.pc +%= signExt8(r8);
        },
        .bpc => {
            // BPC d9, b3, r8
            // Branch near relative address if direct bit is one ("positive"), and clear
            // 0 1 0d8 1b2b1b0 d7d6d5d4d3d2d1d0 r7r6r5r4r3r2r1r0 (48H to 4FH, 58H to 5FH)
            // (PC) ← (PC) + 3, if (d9, b3) = 1 then (PC) ← (PC) + r8, (d9, b3) = 0
            const addr = readEA(cpu, dec);
            const r8 = cpu.fetch8();
            const bit = @as(u3, @intCast(dec.bit.?));
            const val = cpu.load8(addr);
            if ((val >> bit) & 1 != 0) {
                cpu.pc +%= signExt8(r8);
                cpu.store8(addr, val & ~(@as(u8, 1) << bit));
            }
        },
    }
    const used = cycles(dec);
    cpu.tickTimers(used);
    cpu.requestLevelDrivenInterrupts();
    cpu.servicePendingInterrupt();
    if (dbg.checkBiosPhase(cpu)) |phase| {
        if (dbg.log_level == .trace) {
            std.debug.print("[BIOS] Phase: {s} (PC=0x{X:0>4})\n", .{ @tagName(phase), cpu.pc });
        }
        dbg.log("[BIOS] Phase: {s} (PC=0x{X:0>4})", .{ @tagName(phase), cpu.pc });
    }

    if (cpu.halted and dec.inst != .nop) {
        if (dbg.log_level == .trace) {
            dbg.log(">>> HALT at PC={X:0>4} IE={X:0>2} BTCR={X:0>2} T0CNT={X:0>2} T1CNT={X:0>2} P3INT={X:0>2} P3={X:0>2} prevP3={X:0>2}", .{
                cpu.pc,
                cpu.sfr_raw[0x08],
                cpu.sfr_raw[0x7F],
                cpu.sfr_raw[0x10],
                cpu.sfr_raw[0x18],
                cpu.sfr_raw[0x4E],
                cpu.p3_buttons,
                cpu.prev_p3_buttons,
            });
        }
    }

    return used;
}

fn signExt8(val: u8) u16 {
    return @bitCast(@as(i16, @as(i8, @bitCast(val))));
}

fn readIndirectAddr(cpu: *Cpu, ri: u2) u9 {
    const irbk: u4 = @truncate((@as(u8, @bitCast(cpu.psw)) >> 3) & 0b11);
    const reg_addr: u4 = (irbk << 2) | @as(u4, ri);
    const reg_val = cpu.ram_bank0[reg_addr];
    const bit8: u9 = if (ri & 2 != 0) 0x100 else 0;
    return bit8 | reg_val;
}

fn decodeD9addr(dec: DecodeResult, cpu: *Cpu) u9 {
    return @as(u9, @truncate(isa.decodeD9(dec.opcode, cpu.fetch8())));
}

fn readEA(cpu: *Cpu, dec: DecodeResult) u9 {
    return switch (dec.mode) {
        .d9 => decodeD9addr(dec, cpu),
        .ri => readIndirectAddr(cpu, @as(u2, @intCast(dec.ri.?))),
        .impl, .imm => 0, // safety fallback — shouldn't happen with correct opcodes
    };
}

fn readOp8(cpu: *Cpu, dec: DecodeResult) u8 {
    return switch (dec.mode) {
        .imm => cpu.fetch8(),
        .d9 => cpu.load8(decodeD9addr(dec, cpu)),
        .ri => cpu.load8(readIndirectAddr(cpu, @as(u2, @intCast(dec.ri.?)))),
        .impl => 0, // safety fallback
    };
}
