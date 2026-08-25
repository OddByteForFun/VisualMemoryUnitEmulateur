const std = @import("std");
const testing = std.testing;
const Cpu = @import("lc86K").Cpu;
const isa = @import("isa");
const dbg = @import("debug");
const vmu = @import("vmu");
const step = @import("decode").step;

// Tire les blocs test des modules importés dans la passe de tests.
test {
    _ = @import("isa");
    _ = @import("decode");
    _ = @import("debug");
}

fn makeCpu(rom: []u8) Cpu {
    dbg.log_level = .none;
    @memset(rom, 0);
    return Cpu.init(rom);
}

test "TABLE ISA : cohérence structurelle sur les 256 opcodes" {
    for (0..256) |i| {
        const e = &isa.TABLE[i];
        try std.testing.expectEqual(@as(u8, @intCast(i)), e.opcode);
        try std.testing.expect(e.mnemonic.len > 0);
        try std.testing.expect(e.size >= 1 and e.size <= 3);
        try std.testing.expect(e.cycles >= 1);
        switch (e.mode) {
            .ri => try std.testing.expect(e.ri != null),
            else => try std.testing.expect(e.ri == null),
        }
        if (e.bit != null) try std.testing.expectEqual(isa.AddressingMode.d9, e.mode);
    }
}

test "TABLE ISA : points de contrôle du jeu d'instructions" {
    // BRF consomme un offset 16 bits (fetch16) : 3 octets au total.
    try std.testing.expectEqual(isa.Inst.brf, isa.TABLE[0x11].inst);
    try std.testing.expectEqual(@as(u16, 3), isa.TABLE[0x11].size);
    // LDF/STF sont de vraies instructions (accès flash), pas des NOP.
    try std.testing.expectEqualStrings("LDF", isa.TABLE[0x50].mnemonic);
    try std.testing.expectEqualStrings("STF", isa.TABLE[0x51].mnemonic);
    // Dérivation ri = col & 3 et bit = opcode & 7.
    try std.testing.expectEqual(@as(?u8, 1), isa.TABLE[0x05].ri);
    try std.testing.expectEqual(@as(?u8, 5), isa.TABLE[0x4D].bit);
}

test "instSize est piloté par la TABLE ISA (BRF inclus)" {
    var rom: [256]u8 = undefined;
    for (&rom, 0..) |*b, i| b.* = @intCast(i);
    for (0..256) |i| {
        try std.testing.expectEqual(isa.TABLE[i].size, dbg.instSize(&rom, @intCast(i)));
    }
    try std.testing.expectEqual(@as(u16, 3), dbg.instSize(&rom, 0x11));
}

test "disassembleAt couvre les 256 opcodes et corrige LDF/STF" {
    var rom: [65536]u8 = undefined;
    @memset(&rom, 0);
    for (0..256) |i| rom[i] = @intCast(i);
    var cpu = Cpu.init(&rom);
    var buf: [64]u8 = undefined;

    // Aucun opcode ne doit faire planter ou produire une sortie vide.
    for (0..256) |i| {
        const len = dbg.disassembleAt(&cpu, &buf, @intCast(i));
        try std.testing.expect(len > 0);
        try std.testing.expectEqual(@as(u8, ':'), buf[4]);
    }

    // LDF/STF affichés sous leur vrai nom (plus de faux NOP).
    const ldf = dbg.disassembleAt(&cpu, &buf, 0x50);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..ldf], "LDF") != null);
    const stf = dbg.disassembleAt(&cpu, &buf, 0x51);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..stf], "STF") != null);
}

test "ADD immediate VMC-156" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x81; rom[1] = 0x13;
    rom[2] = 0x81; rom[3] = 0x0a;
    rom[4] = 0x81; rom[5] = 0x0f;
    rom[6] = 0x81; rom[7] = 0x80;
    cpu.a = 0x55;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x68), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x72), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x81), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x01), cpu.a);
}

test "ADDC immediate VMC-159" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x81; rom[1] = 0x13;
    rom[2] = 0x91; rom[3] = 0x0a;
    rom[4] = 0x91; rom[5] = 0x0f;
    rom[6] = 0x91; rom[7] = 0x80;
    rom[8] = 0x91; rom[9] = 0x01;
    cpu.a = 0x55;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x68), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x72), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x81), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x01), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x03), cpu.a);
}

test "SUB immediate VMC-160" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0xA1; rom[1] = 0x13;
    rom[2] = 0xA1; rom[3] = 0x03;
    rom[4] = 0xA1; rom[5] = 0x3f;
    rom[6] = 0xA1; rom[7] = 0x02;
    cpu.a = 0x55;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x42), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x3f), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x00), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xfe), cpu.a);
}

test "SUBC indirect VMC-166" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0xA1; rom[1] = 0x16;
    rom[2] = 0xB4; // SUBC @R0 (0xB4 = row 11 col 4, ri=0)
    rom[3] = 0xB4; // SUBC @R0
    cpu.a = 0x55;
    cpu.ram_bank0[0] = 0x68; // R0 via IRBK=0 at addr 0x00 → value 0x68
    cpu.ram_bank0[0x68] = 0x40;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x3f), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xff), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xbe), cpu.a);
}

test "AND immediate VMC-173" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0xE1; rom[1] = 0xfa;
    rom[2] = 0xE1; rom[3] = 0xaf;
    rom[4] = 0xE1; rom[5] = 0x0f;
    rom[6] = 0xE1; rom[7] = 0xf0;
    cpu.a = 0xff;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xfa), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xaa), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x0a), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x00), cpu.a);
}

// ── VMC examples tests ──

test "VMC-156 ADD d9 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // MOV #055H,ACC: 0x23 0x00 0x55
    // MOV #068H,023H: 0x22 0x23 0x68
    // ADD #00CH: 0x81 0x0C
    // ADD 023H: 0x82 0x23
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x55;
    rom[3] = 0x22; rom[4] = 0x23; rom[5] = 0x68;
    rom[6] = 0x81; rom[7] = 0x0C;
    rom[8] = 0x82; rom[9] = 0x23;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x55), cpu.a);
    _ = step(&cpu); // MOV 068H to 023H
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x61), cpu.a); // ACC = 55H+0CH=61H
    try testing.expect(!cpu.psw.cy);
    try testing.expect(cpu.psw.ac);
    try testing.expect(!cpu.psw.ov);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xC9), cpu.a); // ACC = 61H+68H=C9H
    try testing.expect(!cpu.psw.cy);
    try testing.expect(!cpu.psw.ac);
    try testing.expect(cpu.psw.ov);
}

test "VMC-157 ADD @Rj example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // MOV #055H,ACC: 0x23 0x00 0x55
    // MOV #068H,000H: 0x22 0x00 0x68  → RAM[0] = 68H (R0 points here)
    // MOV #010H,@R0: 0x24 0x10        → RAM[68H] = 10H
    // ADD #015H: 0x81 0x15
    // ADD @R0: 0x84                    → ACC += RAM[68H]
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x55;
    rom[3] = 0x22; rom[4] = 0x00; rom[5] = 0x68;
    rom[6] = 0x24; rom[7] = 0x10;
    rom[8] = 0x81; rom[9] = 0x15;
    rom[10] = 0x84;
    _ = step(&cpu); // MOV #055H,ACC
    _ = step(&cpu); // MOV #068H,000H
    _ = step(&cpu); // MOV #010H,@R0
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x6A), cpu.a); // 55H+15H
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x7A), cpu.a); // 6AH+10H
}

test "VMC-158 ADDC imm example" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // MOV #055H,ACC: 0x23 0x00 0x55
    // ADD #013H: 0x81 0x13
    // ADDC #00AH: 0x91 0x0A
    // ADDC #00FH: 0x91 0x0F
    // ADDC #080H: 0x91 0x80
    // ADDC #001H: 0x91 0x01
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x55;
    rom[3] = 0x81; rom[4] = 0x13;
    rom[5] = 0x91; rom[6] = 0x0A;
    rom[7] = 0x91; rom[8] = 0x0F;
    rom[9] = 0x91; rom[10] = 0x80;
    rom[11] = 0x91; rom[12] = 0x01;
    _ = step(&cpu); // MOV
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x68), cpu.a);
    try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x72), cpu.a);
    try testing.expect(cpu.psw.ac);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x81), cpu.a);
    try testing.expect(cpu.psw.ov);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x01), cpu.a);
    try testing.expect(cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x03), cpu.a);
    try testing.expect(!cpu.psw.cy);
}

test "VMC-159 ADDC d9 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // MOV #055H,ACC: 0x23 0x00 0x55
    // MOV #068H,023H: 0x22 0x23 0x68
    // ADD #00CH: 0x81 0x0C
    // ADDC 023H: 0x92 0x23
    // SET1 PSW,7: 0xFF 0x01  (0xFF = row F col F → set1 d8=1, bit=7, d9 addr = 0x101 = PSW)
    // ADDC 023H: 0x92 0x23
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x55;
    rom[3] = 0x22; rom[4] = 0x23; rom[5] = 0x68;
    rom[6] = 0x81; rom[7] = 0x0C;
    rom[8] = 0x92; rom[9] = 0x23;
    rom[10] = 0xFF; rom[11] = 0x01; // SET1 PSW,7 → CY=1
    rom[12] = 0x92; rom[13] = 0x23;
    _ = step(&cpu); // MOV #055H,ACC
    _ = step(&cpu); // MOV #068H,023H
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x61), cpu.a); // 55H+0CH
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xC9), cpu.a); // 61H+0+68H
    try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); // SET1 PSW,7 → CY=1
    try testing.expect(cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x32), cpu.a); // C9H+1+68H=132H→32H
    try testing.expect(cpu.psw.cy);
}

test "VMC-161 SUB d9 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x55;
    rom[3] = 0x22; rom[4] = 0x23; rom[5] = 0x68;
    rom[6] = 0xA1; rom[7] = 0x0C;
    rom[8] = 0xA2; rom[9] = 0x23;
    _ = step(&cpu); // MOV #055H,ACC
    _ = step(&cpu); // MOV #068H,023H
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x49), cpu.a); // 55H-0CH
    try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xE1), cpu.a); // 49H-68H
    try testing.expect(cpu.psw.cy);
}

test "VMC-162 SUB @Rj example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x55;
    rom[3] = 0x22; rom[4] = 0x00; rom[5] = 0x68;
    rom[6] = 0x24; rom[7] = 0x10;
    rom[8] = 0xA1; rom[9] = 0x16;
    rom[10] = 0xA4;
    _ = step(&cpu); // MOV #055H,ACC
    _ = step(&cpu); // MOV #068H,000H
    _ = step(&cpu); // MOV #010H,@R0
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x3F), cpu.a); // 55H-16H
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x2F), cpu.a); // 3FH-10H
}

test "VMC-163 SUBC imm example" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x55;
    rom[3] = 0xA1; rom[4] = 0x13;
    rom[5] = 0xB1; rom[6] = 0x03;
    rom[7] = 0xB1; rom[8] = 0x3F;
    rom[9] = 0xB1; rom[10] = 0x02;
    rom[11] = 0xB1; rom[12] = 0x3E;
    _ = step(&cpu); // MOV #055H,ACC
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x42), cpu.a);
    try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x3F), cpu.a);
    try testing.expect(cpu.psw.ac);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x00), cpu.a);
    try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFE), cpu.a);
    try testing.expect(cpu.psw.cy);
    try testing.expect(cpu.psw.ac);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xBF), cpu.a);
    try testing.expect(!cpu.psw.cy);
    try testing.expect(cpu.psw.ac);
}

test "VMC-164 SUBC d9 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x55;
    rom[3] = 0x22; rom[4] = 0x23; rom[5] = 0x68;
    rom[6] = 0xA1; rom[7] = 0x0C;
    rom[8] = 0xB2; rom[9] = 0x23;
    rom[10] = 0xB2; rom[11] = 0x23;
    _ = step(&cpu); // MOV #055H,ACC
    _ = step(&cpu); // MOV #068H,023H
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x49), cpu.a); // 55H-0CH
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xE1), cpu.a); // 49H-0-68H
    try testing.expect(cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x78), cpu.a); // E1H-1-68H=78H
    try testing.expect(!cpu.psw.cy);
}

test "VMC-165 SUBC @Rj example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x55;
    rom[3] = 0x22; rom[4] = 0x00; rom[5] = 0x68;
    rom[6] = 0x24; rom[7] = 0x40;
    rom[8] = 0xA1; rom[9] = 0x16;
    rom[10] = 0xB4;
    rom[11] = 0xB4;
    _ = step(&cpu); // MOV #055H,ACC
    _ = step(&cpu); // MOV #068H,000H
    _ = step(&cpu); // MOV #040H,@R0
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x3F), cpu.a); // 55H-16H
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a); // 3FH-0-40H
    try testing.expect(cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xBE), cpu.a); // FFH-1-40H
    try testing.expect(!cpu.psw.cy);
}

test "VMC-166 INC d9 example 1 (ACC)" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0xFD;
    rom[3] = 0x63; rom[4] = 0x00; // INC ACC (0x63 = row 6 col 3, bit0=1 → SFR/XRAM, d9_byte=0 → ACC)
    rom[5] = 0x63; rom[6] = 0x00;
    rom[7] = 0x63; rom[8] = 0x00;
    rom[9] = 0x63; rom[10] = 0x00;
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFE), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x00), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x01), cpu.a);
}

test "VMC-167 INC @Rj example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // @R3 accesses SFR space (100H-1FFH): @R3 with RAM[3]=0 → addr=0x100=ACC
    // MOV #000H,003H: RAM[03H]=00H (R3 indirect addr)
    // MOV #0FDH,@R3:  ACC = FDH (@R3 → SFR 0x100 via RAM[3]=0)
    // INC @R3: ACC=FEH, FFH, 00H
    rom[0] = 0x22; rom[1] = 0x03; rom[2] = 0x00;
    rom[3] = 0x27; rom[4] = 0xFD; // MOV #0FDH,@R3 (0x27 = row 2 col 7, ri=3)
    rom[5] = 0x67; // INC @R3 (0x67 = row 6 col 7, ri=3)
    rom[6] = 0x67;
    rom[7] = 0x67;
    _ = step(&cpu); // MOV #000H,003H
    _ = step(&cpu); // MOV #0FDH,@R3 → ACC = FDH
    try testing.expectEqual(@as(u8, 0xFD), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFE), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x00), cpu.a);
}

test "VMC-168 DEC d9 example 1 (ACC)" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x02;
    rom[3] = 0x73; rom[4] = 0x00; // DEC ACC (0x73 = row 7 col 3, bit0=1 → SFR)
    rom[5] = 0x73; rom[6] = 0x00;
    rom[7] = 0x73; rom[8] = 0x00;
    rom[9] = 0x73; rom[10] = 0x00;
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x01), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x00), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFE), cpu.a);
}

test "VMC-168 DEC d9 example 2 (RAM)" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x22; rom[1] = 0x7F; rom[2] = 0x02;
    rom[3] = 0x72; rom[4] = 0x7F; // DEC 07FH
    rom[5] = 0x72; rom[6] = 0x7F;
    rom[7] = 0x72; rom[8] = 0x7F;
    rom[9] = 0x72; rom[10] = 0x7F;
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x01), cpu.ram_bank0[0x7F]);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x00), cpu.ram_bank0[0x7F]);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x7F]);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFE), cpu.ram_bank0[0x7F]);
}

test "VMC-173 AND d9 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0xFF;
    rom[3] = 0x22; rom[4] = 0x23; rom[5] = 0x55;
    rom[6] = 0xE2; rom[7] = 0x23; // AND 023H
    rom[8] = 0x22; rom[9] = 0x23; rom[10] = 0xAA;
    rom[11] = 0xE2; rom[12] = 0x23;
    _ = step(&cpu); // MOV #0FFH,ACC
    _ = step(&cpu); // MOV #055H,023H
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x55), cpu.a);
    _ = step(&cpu); // MOV #0AAH,023H
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x00), cpu.a);
}

test "VMC-174 AND @Rj example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0xFF;
    rom[3] = 0x22; rom[4] = 0x00; rom[5] = 0x68;
    rom[6] = 0x24; rom[7] = 0xF0;
    rom[8] = 0xE4; // AND @R0
    rom[9] = 0x24; rom[10] = 0x0F;
    rom[11] = 0xE4;
    _ = step(&cpu); // MOV #0FFH,ACC
    _ = step(&cpu); // MOV #068H,000H
    _ = step(&cpu); // MOV #0F0H,@R0
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xF0), cpu.a);
    _ = step(&cpu); // MOV #00FH,@R0
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x00), cpu.a);
}

test "VMC-175 OR imm example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x00;
    rom[3] = 0xD1; rom[4] = 0x03;
    rom[5] = 0xD1; rom[6] = 0x0C;
    rom[7] = 0xD1; rom[8] = 0x30;
    rom[9] = 0xD1; rom[10] = 0xC0;
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x03), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x0F), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x3F), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a);
}

test "VMC-176 OR d9 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x00;
    rom[3] = 0x22; rom[4] = 0x23; rom[5] = 0x55;
    rom[6] = 0xD2; rom[7] = 0x23;
    rom[8] = 0x22; rom[9] = 0x23; rom[10] = 0xAA;
    rom[11] = 0xD2; rom[12] = 0x23;
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x55), cpu.a);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a);
}

test "VMC-177 OR @Rj example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x00;
    rom[3] = 0x22; rom[4] = 0x00; rom[5] = 0x68;
    rom[6] = 0x24; rom[7] = 0xF0;
    rom[8] = 0xD4; // OR @R0
    rom[9] = 0x24; rom[10] = 0x0F;
    rom[11] = 0xD4;
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xF0), cpu.a);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a);
}

test "VMC-178 XOR imm example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x00;
    rom[3] = 0xF1; rom[4] = 0x0F;
    rom[5] = 0xF1; rom[6] = 0xF0;
    rom[7] = 0xF1; rom[8] = 0x0F;
    rom[9] = 0xF1; rom[10] = 0xF0;
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x0F), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xF0), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x00), cpu.a);
}

test "VMC-179 XOR d9 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x00;
    rom[3] = 0x22; rom[4] = 0x23; rom[5] = 0x55;
    rom[6] = 0xF2; rom[7] = 0x23; // XOR 023H
    rom[8] = 0x22; rom[9] = 0x23; rom[10] = 0xFF;
    rom[11] = 0xF2; rom[12] = 0x23;
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x55), cpu.a);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xAA), cpu.a);
}

test "VMC-180 XOR @Rj example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x00;
    rom[3] = 0x22; rom[4] = 0x01; rom[5] = 0x68;
    rom[6] = 0x25; rom[7] = 0xF0; // MOV #0F0H,@R1 (0x25=row2 col5, ri=1)
    rom[8] = 0xF5; // XOR @R1 (0xF5=row F col5, ri=1)
    rom[9] = 0x25; rom[10] = 0xFF;
    rom[11] = 0xF5;
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xF0), cpu.a);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x0F), cpu.a);
}

test "VMC-181 ROL sequence" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    @memset(&rom, 0xE0); // ROL
    cpu.a = 0x01;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x02), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x04), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x08), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x10), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x20), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x40), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x80), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x01), cpu.a);
    cpu.a = 0x55;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xAA), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x55), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xAA), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x55), cpu.a);
}

test "VMC-182 ROLC sequence" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    @memset(&rom, 0xF0); // ROLC
    cpu.a = 0x01;
    cpu.psw.cy = true;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x03), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x06), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x0C), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x18), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x30), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x60), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xC0), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x80), cpu.a); try testing.expect(cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x01), cpu.a); try testing.expect(cpu.psw.cy);
}

test "VMC-183 ROR sequence" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    @memset(&rom, 0xC0); // ROR
    cpu.a = 0x01;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x80), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x40), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x20), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x10), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x08), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x04), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x02), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x01), cpu.a);
}

test "VMC-184 RORC sequence" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    @memset(&rom, 0xD0); // RORC
    cpu.a = 0x01;
    cpu.psw.cy = true;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x80), cpu.a); try testing.expect(cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xC0), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x60), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x30), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x18), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x0C), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x06), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x03), cpu.a); try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x01), cpu.a); try testing.expect(cpu.psw.cy);
}

test "VMC-185 LD d9 (SFR) example" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0xFF; // MOV #0FFH,ACC
    rom[3] = 0x23; rom[4] = 0x02; rom[5] = 0xF0; // MOV #0F0H,B
    rom[6] = 0x23; rom[7] = 0x06; rom[8] = 0x0F; // MOV #00FH,SP
    rom[9] = 0x03; rom[10] = 0x02; // LD B (0x03=row0 col3, d9_byte=0x02 → addr=0x102=B)
    rom[11] = 0x03; rom[12] = 0x06; // LD SP (0x03, d9_byte=0x06 → addr=0x106=SP)
    rom[13] = 0x03; rom[14] = 0x02; // LD B
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xF0), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x0F), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xF0), cpu.a);
}

test "VMC-186 LD @Rj example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0xFF;
    rom[3] = 0x22; rom[4] = 0x00; rom[5] = 0x70;
    rom[6] = 0x22; rom[7] = 0x01; rom[8] = 0x7F;
    rom[9] = 0x24; rom[10] = 0xF0; // MOV #0F0H,@R0
    rom[11] = 0x25; rom[12] = 0x0F; // MOV #00FH,@R1
    rom[13] = 0x04; // LD @R0 (0x04=row0 col4, ri=0)
    rom[14] = 0x05; // LD @R1 (0x05=row0 col5, ri=1)
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xF0), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x0F), cpu.a);
}

test "VMC-187 ST d9 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0xFF;
    rom[3] = 0x22; rom[4] = 0x70; rom[5] = 0x55;
    rom[6] = 0x22; rom[7] = 0x71; rom[8] = 0xAA;
    rom[9] = 0x12; rom[10] = 0x70; // ST 070H (0x12=row1 col2)
    rom[11] = 0x23; rom[12] = 0x00; rom[13] = 0x00; // MOV #000H,ACC
    rom[14] = 0x12; rom[15] = 0x71;
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu); // ST 070H
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x70]);
    _ = step(&cpu); // MOV #000H,ACC
    _ = step(&cpu); // ST 071H
    try testing.expectEqual(@as(u8, 0x00), cpu.ram_bank0[0x71]);
}

test "VMC-188 ST @Rj example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0xFF;
    rom[3] = 0x22; rom[4] = 0x00; rom[5] = 0x70;
    rom[6] = 0x22; rom[7] = 0x01; rom[8] = 0x7F;
    rom[9] = 0x24; rom[10] = 0xF0; // MOV #0F0H,@R0
    rom[11] = 0x25; rom[12] = 0x0F; // MOV #00FH,@R1
    rom[13] = 0x14; // ST @R0 (0x14=row1 col4, ri=0)
    rom[14] = 0x15; // ST @R1 (0x15=row1 col5, ri=1)
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x70]);
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x7F]);
}

test "VMC-189 MOV imm,d9 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x22; rom[1] = 0x00; rom[2] = 0xFF;
    rom[3] = 0x22; rom[4] = 0x01; rom[5] = 0xFE;
    rom[6] = 0x22; rom[7] = 0x02; rom[8] = 0xFD;
    rom[9] = 0x22; rom[10] = 0x03; rom[11] = 0xFC;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x00]);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFE), cpu.ram_bank0[0x01]);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFD), cpu.ram_bank0[0x02]);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFC), cpu.ram_bank0[0x03]);
}

test "VMC-189 MOV imm,d9 example 2 (SFR)" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0xFF; // MOV #0FFH,ACC
    rom[3] = 0x23; rom[4] = 0x02; rom[5] = 0xFE; // MOV #0FEH,B
    rom[6] = 0x23; rom[7] = 0x04; rom[8] = 0xFD; // MOV #0FDH,TRL
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFE), cpu.b);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFD), cpu.trl);
}

test "VMC-190 MOV imm,@Rj example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // MOV #07FH,000H → RAM[0]=7FH, MOV #07EH,001H → RAM[1]=7EH
    // MOV #0FDH,@R0 → RAM[7FH]=FDH
    rom[0] = 0x22; rom[1] = 0x00; rom[2] = 0x7F;
    rom[3] = 0x22; rom[4] = 0x01; rom[5] = 0x7E;
    rom[6] = 0x24; rom[7] = 0xFD; // MOV #0FDH,@R0
    rom[8] = 0x25; rom[9] = 0xFC; // MOV #0FCH,@R1
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFD), cpu.ram_bank0[0x7F]);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFC), cpu.ram_bank0[0x7E]);
}

test "VMC-192 PUSH/POP sequence" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // MOV #0AAH,ACC; MOV #055H,B; MOV #012H,000H; MOV #01FH,SP
    // PUSH ACC (0x61 0x00); PUSH B (0x61 0x02); PUSH 000H (0x60 0x00)
    // POP B (0x71 0x02); POP ACC (0x71 0x00); POP 000H (0x70 0x00)
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0xAA;
    rom[3] = 0x23; rom[4] = 0x02; rom[5] = 0x55;
    rom[6] = 0x22; rom[7] = 0x00; rom[8] = 0x12;
    rom[9] = 0x23; rom[10] = 0x06; rom[11] = 0x1F;
    rom[12] = 0x61; rom[13] = 0x00; // PUSH ACC
    rom[14] = 0x61; rom[15] = 0x02; // PUSH B
    rom[16] = 0x60; rom[17] = 0x00; // PUSH 000H
    rom[18] = 0x71; rom[19] = 0x02; // POP B
    rom[20] = 0x71; rom[21] = 0x00; // POP ACC
    rom[22] = 0x70; rom[23] = 0x00; // POP 000H
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu); // SP = 1FH
    _ = step(&cpu); // PUSH ACC → SP=20H, stack[20H]=AAH
    try testing.expectEqual(@as(u8, 0x20), cpu.sp);
    try testing.expectEqual(@as(u8, 0xAA), cpu.ram_bank0[0x20]);
    _ = step(&cpu); // PUSH B → SP=21H, stack[21H]=55H
    try testing.expectEqual(@as(u8, 0x55), cpu.ram_bank0[0x21]);
    _ = step(&cpu); // PUSH 000H → SP=22H, stack[22H]=12H
    try testing.expectEqual(@as(u8, 0x12), cpu.ram_bank0[0x22]);
    _ = step(&cpu); // POP B → B=12H, SP=21H
    try testing.expectEqual(@as(u8, 0x12), cpu.b);
    try testing.expectEqual(@as(u8, 0x21), cpu.sp);
    _ = step(&cpu); // POP ACC → ACC=55H, SP=20H
    try testing.expectEqual(@as(u8, 0x55), cpu.a);
    _ = step(&cpu); // POP 000H → RAM[0]=AAH, SP=1FH
    try testing.expectEqual(@as(u8, 0xAA), cpu.ram_bank0[0x00]);
    try testing.expectEqual(@as(u8, 0x1F), cpu.sp);
}

test "VMC-194 XCH d9 example 2 (B)" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0xFF;
    rom[3] = 0x23; rom[4] = 0x02; rom[5] = 0xFE; // MOV #0FEH,B
    rom[6] = 0xC3; rom[7] = 0x02; // XCH B (0xC3 row C col 3, d9 addr=0x102=B)
    rom[8] = 0xC3; rom[9] = 0x02;
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFE), cpu.a);
    try testing.expectEqual(@as(u8, 0xFF), cpu.b);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a);
    try testing.expectEqual(@as(u8, 0xFE), cpu.b);
}

test "VMC-195 XCH @Rj example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0xFF;
    rom[3] = 0x22; rom[4] = 0x01; rom[5] = 0x68;
    rom[6] = 0x25; rom[7] = 0xF0; // MOV #0F0H,@R1
    rom[8] = 0xC5; // XCH @R1 (0xC5=row C col5, ri=1)
    rom[9] = 0xC5;
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xF0), cpu.a);
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x68]);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a);
    try testing.expectEqual(@as(u8, 0xF0), cpu.ram_bank0[0x68]);
}

test "VMC-196 JMP a12 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // At 0FFBH: NOP, at 0FFCH: NOP
    // JMP LA at 0FFDH: opcode 0x3F (row3 colF), imm8=0x0E → a12=(0x0F<<8)|0x0E=0xF0E
    rom[0xFFB] = 0x00; // NOP
    rom[0xFFC] = 0x00; // NOP
    rom[0xFFD] = 0x3F; // JMP a12
    rom[0xFFE] = 0x0E; // imm8
    rom[0xF0E] = 0x63; rom[0xF0F] = 0x00; // INC ACC
    rom[0xF10] = 0xC0; // ROR
    cpu.pc = 0xFFB;
    _ = step(&cpu); try testing.expectEqual(@as(u16, 0xFFC), cpu.pc);
    _ = step(&cpu); try testing.expectEqual(@as(u16, 0xFFD), cpu.pc);
    _ = step(&cpu); // JMP: PC=(0xFFF&0xF000)|0xF0E = 0xF0E
    try testing.expectEqual(@as(u16, 0xF0E), cpu.pc);
    _ = step(&cpu); // INC ACC
    try testing.expectEqual(@as(u16, 0xF10), cpu.pc);
}

test "VMC-197 JMPF example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // NOP; NOP; JMPF LA: 0x21 0x0F 0x0E → PC=0F0EH
    rom[0xFFA] = 0x00; rom[0xFFB] = 0x00;
    rom[0xFFC] = 0x21; // JMPF
    rom[0xFFD] = 0x0F; // hi
    rom[0xFFE] = 0x0E; // lo
    rom[0xF0E] = 0x63; rom[0xF0F] = 0x00; // INC ACC
    rom[0xF10] = 0xC0; // ROR
    cpu.pc = 0xFFA;
    _ = step(&cpu); try testing.expectEqual(@as(u16, 0xFFB), cpu.pc);
    _ = step(&cpu); try testing.expectEqual(@as(u16, 0xFFC), cpu.pc);
    _ = step(&cpu); // JMPF 0F0EH
    try testing.expectEqual(@as(u16, 0xF0E), cpu.pc);
}

test "VMC-200 BZ taken (ACC=0)" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // MOV #000H,ACC; BZ LA; INC ACC; ROR; LA: INC ACC; ROR
    // offset for BZ from 0F1EH to 0F5FH = 0x41
    rom[0xF19] = 0x23; rom[0xF1A] = 0x00; rom[0xF1B] = 0x00;
    rom[0xF1C] = 0x80; rom[0xF1D] = 0x41; // BZ LA
    rom[0xF1E] = 0x63; rom[0xF1F] = 0x00; // INC ACC (should not execute)
    rom[0xF20] = 0xC0; // ROR (should not execute)
    rom[0xF5F] = 0x63; rom[0xF60] = 0x00; // LA: INC ACC
    rom[0xF61] = 0xC0; // ROR
    cpu.pc = 0xF19;
    _ = step(&cpu); // MOV #000H,ACC
    _ = step(&cpu); // BZ, ACC=0 → taken
    try testing.expectEqual(@as(u16, 0xF5F), cpu.pc);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x01), cpu.a);
}

test "VMC-200 BZ not taken (ACC≠0)" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0xF19] = 0x23; rom[0xF1A] = 0x00; rom[0xF1B] = 0x01;
    rom[0xF1C] = 0x80; rom[0xF1D] = 0x41;
    rom[0xF1E] = 0x63; rom[0xF1F] = 0x00; // INC ACC (should execute)
    rom[0xF20] = 0xC0; // ROR
    cpu.pc = 0xF19;
    _ = step(&cpu);
    _ = step(&cpu); // BZ, ACC=1 → not taken
    try testing.expectEqual(@as(u16, 0xF1E), cpu.pc);
}

test "VMC-203 BPC bit set, branch and clear" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // MOV #003H,B; BPC B,0,LA; LA: INC B
    // BPC encoding: row 4/5, col 8-F, bit=opcode&7
    // For bit 0: opcode = 0x48 or 0x58. Using 0x58 (row 5 col 8)
    // d9 addr for B: SFR 0x102 → bit0=1 → col=9? No, d9 uses opcode bit0 for addr bit8
    // B is at 0x102: bit8=1, low byte=0x02 → opcode bit0=1
    // BPC has col 8,8+bit for bit selection. So col 8 for bit0, and col 8 means opcode=0x58
    // But d9 bit0 needs opcode bit0=1 → opcode=0x59? 
    // Let me reconsider. BPC encodes bits as opcode&0x7:
    // opcode 0x48: bit=0, opcode&1=0 → addr bit8=0
    // opcode 0x49: bit=1, opcode&1=1 → addr bit8=1
    // So for bit=0, addr bit8=1: opcode = 0x49 (row4 col9)
    // Wait, that mixes bit selection and addr bit8...
    // Actually looking at the decode table:
    // row 4 col 8-F → BPC d9, bit=opcode&7
    // But opcode bit 0 is ALSO the d9 addr bit8!
    // So for BPC d9 where d9 addr's bit8=1 and we want bit 0: opcode=0x48|0x01|0=0x49
    // Hmm, but 0x49 = row 4 col 9, which IS in the BPC range (col 8-F)
    // bit = opcode & 7 = 0x49 & 7 = 1 → bit 1, not bit 0!
    // So there's a conflict: opcode bit0 serves double duty.
    // Let me just use a RAM address instead of SFR for simplicity:
    // B at RAM[0x10], d9 addr=0x10 → bit8=0 → opcode bit0=0
    // bit=0 → opcode=0x48, d9_byte=0x10
    rom[0xF1A] = 0x22; rom[0xF1B] = 0x10; rom[0xF1C] = 0x03; // MOV #003H,010H
    rom[0xF1D] = 0x48; rom[0xF1E] = 0x10; rom[0xF1F] = 0x3F; // BPC 010H,0,LA (offset=+63→0F5FH?)
    // Wait, PC after BPC fetch = 0xF20. LA at 0xF5F: offset = 0xF5F-0xF20 = 0x3F → 0x3F correct!
    rom[0xF5F] = 0x62; rom[0xF60] = 0x10; // INC 010H
    cpu.pc = 0xF1A;
    _ = step(&cpu); // MOV #003H,010H
    try testing.expectEqual(@as(u8, 0x03), cpu.ram_bank0[0x10]);
    _ = step(&cpu); // BPC: bit0=1 → taken, clear bit
    try testing.expectEqual(@as(u8, 0x02), cpu.ram_bank0[0x10]); // bit cleared
    try testing.expectEqual(@as(u16, 0xF5F), cpu.pc);
}

test "VMC-205 DBNZ d9 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // MOV #002H,B → MOV #002H,102H (B SFR addr 0x102)
    // DBNZ B,LA: 0x53 0x02 0x3F (d9 addr=0x102, bit8=1 → opcode=0x53, d9_byte=0x02)
    // Actually wait - DBNZ d9 uses row 5 col 2-3. Col 2 → bit0=0 (addr<256). Col 3 → bit0=1 (addr>=256).
    // B is at SFR 0x102, so bit8=1 → need opcode 0x53
    // DBNZ d9 uses opcode 0x52/0x53 (col 2/3)
    // But there's no bit field for DBNZ (it's not a bit instruction)
    // So 0x53 = row 5 col 3, d9 addr bit8=1
    rom[0xF1A] = 0x23; rom[0xF1B] = 0x02; rom[0xF1C] = 0x02; // MOV #002H,B
    rom[0xF1D] = 0x53; rom[0xF1E] = 0x02; rom[0xF1F] = 0x3F; // DBNZ B,LA (+63)
    rom[0xF5F] = 0x63; rom[0xF60] = 0x00; // INC ACC (LA)
    cpu.pc = 0xF1A;
    cpu.a = 0x55;
    _ = step(&cpu); // MOV #002H,B → B=2
    _ = step(&cpu); // DBNZ B: B=1 ≠ 0 → branch
    try testing.expectEqual(@as(u8, 0x01), cpu.b);
    try testing.expectEqual(@as(u16, 0xF5F), cpu.pc);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x56), cpu.a); // INC ACC
}

test "VMC-207 BE imm taken" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // MOV #002H,ACC; BE #002H,LA
    rom[0xF1A] = 0x23; rom[0xF1B] = 0x00; rom[0xF1C] = 0x02;
    rom[0xF1D] = 0x31; rom[0xF1E] = 0x02; rom[0xF1F] = 0x3F; // BE #002H,LA
    rom[0xF5F] = 0x63; rom[0xF60] = 0x00; // LA: INC ACC
    cpu.pc = 0xF1A;
    _ = step(&cpu); // MOV
    _ = step(&cpu); // BE: ACC=02H == #02H → branch, CY=0
    try testing.expect(!cpu.psw.cy);
    try testing.expectEqual(@as(u16, 0xF5F), cpu.pc);
}

test "VMC-207 BE imm not taken" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0xF1A] = 0x23; rom[0xF1B] = 0x00; rom[0xF1C] = 0x03;
    rom[0xF1D] = 0x31; rom[0xF1E] = 0x04; rom[0xF1F] = 0x3F; // BE #004H,LA
    rom[0xF20] = 0xA1; rom[0xF21] = 0x01; // DEC ACC
    cpu.pc = 0xF1A;
    _ = step(&cpu);
    _ = step(&cpu); // BE: ACC(03H) < #04H → CY=1, no branch
    try testing.expect(cpu.psw.cy);
    try testing.expectEqual(@as(u16, 0xF20), cpu.pc);
}

test "VMC-210 BNE imm taken" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0xF1A] = 0x23; rom[0xF1B] = 0x00; rom[0xF1C] = 0x02;
    rom[0xF1D] = 0x41; rom[0xF1E] = 0x00; rom[0xF1F] = 0x3F; // BNE #000H,LA
    rom[0xF5F] = 0x63; rom[0xF60] = 0x00;
    cpu.pc = 0xF1A;
    _ = step(&cpu);
    _ = step(&cpu); // BNE: ACC(02H) != #00H → branch
    try testing.expect(!cpu.psw.cy);
    try testing.expectEqual(@as(u16, 0xF5F), cpu.pc);
}

test "VMC-210 BNE imm not taken" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0xF1A] = 0x23; rom[0xF1B] = 0x00; rom[0xF1C] = 0x03;
    rom[0xF1D] = 0x41; rom[0xF1E] = 0x03; rom[0xF1F] = 0x3F; // BNE #003H,LA
    rom[0xF20] = 0xA1; rom[0xF21] = 0x01; // DEC ACC
    cpu.pc = 0xF1A;
    _ = step(&cpu);
    _ = step(&cpu); // BNE: ACC(03H) == #03H → no branch
    try testing.expect(!cpu.psw.cy);
    try testing.expectEqual(@as(u16, 0xF20), cpu.pc);
}

test "CLR1 d9 bit0 — ACC (SFR) et RAM" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x01;
    rom[3] = 0xD8; rom[4] = 0x00;
    rom[5] = 0x22; rom[6] = 0x7F; rom[7] = 0x01;
    rom[8] = 0xC8; rom[9] = 0x7F;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x01), cpu.a);
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x00), cpu.a);
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x01), cpu.ram_bank0[0x7F]);
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x00), cpu.ram_bank0[0x7F]);
}

test "VMC-213 CALL a12 example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // CALL a12: opcode 0x1F (row1 colF), imm8=0x0E → a12=(0x10)<<7|(0x07)<<8|0x0E=0xF0E
    // At 0FFAH: MOV #01FH,SP; CALL LA; LA: INC ACC; RET; NOP
    rom[0xFFA] = 0x23; rom[0xFFB] = 0x06; rom[0xFFC] = 0x1F; // MOV #01FH,SP
    rom[0xFFD] = 0x1F; rom[0xFFE] = 0x0E; // CALL LA
    rom[0xF0E] = 0x63; rom[0xF0F] = 0x00; // INC ACC
    rom[0xF10] = 0xA0; // RET
    rom[0xFFF] = 0x00; // NOP (next after return)
    cpu.a = 0xFF;
    cpu.pc = 0xFFA;
    _ = step(&cpu); // MOV #01FH,SP → SP=1FH
    _ = step(&cpu); // CALL LA → push return(0xFFF), jump to 0xF0E
    try testing.expectEqual(@as(u16, 0xF0E), cpu.pc);
    try testing.expectEqual(@as(u8, 0x21), cpu.sp);
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x20]);
    try testing.expectEqual(@as(u8, 0x0F), cpu.ram_bank0[0x21]);
    _ = step(&cpu); // INC ACC → ACC=0x00
    try testing.expectEqual(@as(u8, 0x00), cpu.a);
    _ = step(&cpu); // RET → pop PC=0xFFF
    try testing.expectEqual(@as(u16, 0xFFF), cpu.pc);
    try testing.expectEqual(@as(u8, 0x1F), cpu.sp);
}

test "VMC-214 CALLF example 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0xFF9] = 0x23; rom[0xFFA] = 0x06; rom[0xFFB] = 0x1F; // MOV #01FH,SP
    rom[0xFFC] = 0x20; rom[0xFFD] = 0x0F; rom[0xFFE] = 0x0E; // CALLF 0F0EH
    rom[0xF0E] = 0x63; rom[0xF0F] = 0x00; // INC ACC
    rom[0xF10] = 0xA0; // RET
    rom[0xFFF] = 0x00; // NOP
    cpu.a = 0xFF;
    cpu.pc = 0xFF9;
    _ = step(&cpu); // MOV #01FH,SP
    _ = step(&cpu); // CALLF 0F0EH
    try testing.expectEqual(@as(u16, 0xF0E), cpu.pc);
    try testing.expectEqual(@as(u8, 0x21), cpu.sp);
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x20]);
    try testing.expectEqual(@as(u8, 0x0F), cpu.ram_bank0[0x21]);
    _ = step(&cpu); // INC ACC
    try testing.expectEqual(@as(u8, 0x00), cpu.a);
    _ = step(&cpu); // RET
    try testing.expectEqual(@as(u16, 0xFFF), cpu.pc);
}

test "initVmuFlash : structure du système de fichiers" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);

    vmu.initVmuFlash(&cpu);

    // Flash effacée = 0xFF, puis structures écrites par-dessus
    const rb: usize = 255 * 512;
    for (0..16) |i| {
        try testing.expectEqual(@as(u8, 0x55), cpu.flash[rb + i]); // magic
    }
    try testing.expectEqual(@as(u8, 0xFE), cpu.flash[rb + 0x46]); // FATFirst
    try testing.expectEqual(@as(u8, 0x00), cpu.flash[rb + 0x47]);
    try testing.expectEqual(@as(u8, 0xFD), cpu.flash[rb + 0x4A]); // DirLast
    try testing.expectEqual(@as(u8, 0x0D), cpu.flash[rb + 0x4C]); // DirSize
    try testing.expectEqual(@as(u8, 0xC8), cpu.flash[rb + 0x50]); // HiddenFirst
    try testing.expectEqual(@as(u8, 0x80), cpu.flash[rb + 0x56]); // GameSize

    // FAT : root et FAT marqués LastInFile (FFFA), répertoire chaîné 253→241
    const fb: usize = 254 * 512;
    try testing.expectEqual(@as(u8, 0xFA), cpu.flash[fb + 255 * 2]);
    try testing.expectEqual(@as(u8, 0xFF), cpu.flash[fb + 255 * 2 + 1]);
    try testing.expectEqual(@as(u8, 0xFA), cpu.flash[fb + 254 * 2]);
    try testing.expectEqual(@as(u8, 0xFC), cpu.flash[fb + 253 * 2]); // 253 → 252
    try testing.expectEqual(@as(u8, 0xF1), cpu.flash[fb + 242 * 2]); // 242 → 241
    try testing.expectEqual(@as(u8, 0xFA), cpu.flash[fb + 241 * 2]);

    // Bloc utilisateur hors jeu : effacé
    try testing.expectEqual(@as(u8, 0xFF), cpu.flash[100 * 512]);
}

test "installGame : entrée répertoire et chaîne FAT" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    vmu.initVmuFlash(&cpu);

    const game_size: usize = 1024; // 2 blocs
    vmu.installGame(&cpu, game_size);

    const dir_base = 253 * 512;
    try testing.expectEqual(@as(u8, 0xCC), cpu.flash[dir_base + 0x00]); // Game
    try testing.expectEqual(@as(u8, 0x80), cpu.flash[dir_base + 0x01]); // non protégé
    try testing.expectEqualStrings("GAME", cpu.flash[dir_base + 0x04 .. dir_base + 0x08]);
    try testing.expectEqual(@as(u8, 2), cpu.flash[dir_base + 0x18]); // SizeInBlocks
    try testing.expectEqual(@as(u8, 0x00), cpu.flash[dir_base + 0x1A]); // header bloc 0

    // Chaîne FAT : bloc 0 → 1 → LastInFile
    const fb: usize = 254 * 512;
    try testing.expectEqual(@as(u8, 0x01), cpu.flash[fb + 0]); // bloc 0 → 1
    try testing.expectEqual(@as(u8, 0xFA), cpu.flash[fb + 2]); // bloc 1 → last
    try testing.expectEqual(@as(u8, 0xFF), cpu.flash[fb + 3]);
}

test "initBiosRtc : état attendu par le BIOS" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);

    vmu.initBiosRtc(&cpu);

    try testing.expectEqual(@as(u16, 0x2E1), cpu.pc); // saute la requête date série
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x31]); // DateTime_DateSet
    try testing.expectEqual(@as(u8, 0x20), cpu.ram_bank0[0x10]); // siècle BCD
    try testing.expectEqual(@as(u8, 0xFF), cpu.sfr_raw[Cpu.SFR_IE]);
    try testing.expectEqual(@as(u8, 0xFD), cpu.sfr_raw[Cpu.SFR_P3INT]);
    try testing.expectEqual(@as(u8, 0xC0), cpu.sfr_raw[Cpu.SFR_ISL]);
    try testing.expectEqual(@as(u8, 0x41), cpu.sfr_raw[Cpu.SFR_BTCR]);
}

// ── Interruptions / Timers / HALT ─────────────────────────
// Verrouille le comportement de servicePendingInterrupt(), des timers Mode 0
// et du réveil HALT avant d'empiler les périphériques P1 par-dessus.

/// Réarme les verrous internes pour servir l'IRQ suivante (comme après RETI).
fn allowNextIrq(cpu: *Cpu) void {
    cpu.interrupt_depth = 0;
    cpu.process_this_instr = true;
}

test "IRQ : EA=0 bloque tout service" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // Écritures directes : pas de période interrupt_blocked (déclenchée seulement via storeSFR).
    cpu.sfr_raw[Cpu.SFR_IE] = 0x00; // EA=0
    cpu.sfr_raw[Cpu.SFR_T0CNT] = Cpu.T0CNT_T0LOVF | Cpu.T0CNT_T0LIE;

    cpu.servicePendingInterrupt();

    try testing.expectEqual(@as(u16, 0x0000), cpu.pc);
    try testing.expectEqual(@as(u8, 0), cpu.interrupt_depth);
    try testing.expectEqual(Cpu.T0CNT_T0LOVF | Cpu.T0CNT_T0LIE, cpu.sfr_raw[Cpu.SFR_T0CNT]); // flag intact
}

test "IRQ : priorité int2 > int3 > t0h > t1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    cpu.sfr_raw[Cpu.SFR_IE] = 0x80; // écriture directe, EA seul suffit ici
    // Toutes les sources actives simultanément.
    cpu.sfr_raw[Cpu.SFR_T0CNT] = Cpu.T0CNT_T0LOVF | Cpu.T0CNT_T0LIE |
        Cpu.T0CNT_T0HOVF | Cpu.T0CNT_T0HIE;
    cpu.sfr_raw[Cpu.SFR_BTCR] = Cpu.BTCR_BT0_FLAG | Cpu.BTCR_BT0_IE |
        Cpu.BTCR_BT1_FLAG | Cpu.BTCR_BT1_IE;
    cpu.sfr_raw[Cpu.SFR_T1CNT] = Cpu.T1CNT_T1HOVF | Cpu.T1CNT_T1HIE |
        Cpu.T1CNT_T1LOVF | Cpu.T1CNT_T1LIE;

    cpu.servicePendingInterrupt(); // int2 gagne
    try testing.expectEqual(@as(u16, 0x0013), cpu.pc);
    // Seul le flag T0LOVF est effacé ; les bits enable restent posés.
    try testing.expectEqual(Cpu.T0CNT_T0HOVF | Cpu.T0CNT_T0HIE | Cpu.T0CNT_T0LIE, cpu.sfr_raw[Cpu.SFR_T0CNT]);

    allowNextIrq(&cpu);
    cpu.servicePendingInterrupt(); // int3 ensuite
    try testing.expectEqual(@as(u16, 0x001B), cpu.pc);

    allowNextIrq(&cpu);
    cpu.servicePendingInterrupt(); // t0h ensuite
    try testing.expectEqual(@as(u16, 0x0023), cpu.pc);
    const t0cnt_left = cpu.sfr_raw[Cpu.SFR_T0CNT];
    try testing.expectEqual(@as(u8, 0), t0cnt_left & (Cpu.T0CNT_T0LOVF | Cpu.T0CNT_T0HOVF));

    allowNextIrq(&cpu);
    cpu.servicePendingInterrupt(); // t1 en dernier
    try testing.expectEqual(@as(u16, 0x002B), cpu.pc);
    const t1cnt_left = cpu.sfr_raw[Cpu.SFR_T1CNT];
    try testing.expectEqual(@as(u8, 0), t1cnt_left & (Cpu.T1CNT_T1LOVF | Cpu.T1CNT_T1HOVF));
}

test "IRQ : push PC/SP et saut au vecteur" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    cpu.pc = 0x1234;
    cpu.sfr_raw[Cpu.SFR_T0CNT] = Cpu.T0CNT_T0LOVF | Cpu.T0CNT_T0LIE;

    cpu.servicePendingInterrupt();

    try testing.expectEqual(@as(u8, 0x81), cpu.sp);
    try testing.expectEqual(@as(u8, 0x34), cpu.ram_bank0[0x80]); // PC bas poussé premier
    try testing.expectEqual(@as(u8, 0x12), cpu.ram_bank0[0x81]);
    try testing.expectEqual(@as(u16, 0x0013), cpu.pc);
    try testing.expectEqual(@as(u8, 1), cpu.interrupt_depth);
    try testing.expect(!cpu.halted);
}

test "IRQ : blocage un cycle après écriture IE/IP" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    cpu.sfr_raw[Cpu.SFR_T0CNT] = Cpu.T0CNT_T0LOVF | Cpu.T0CNT_T0LIE;

    cpu.storeSFR(Cpu.SFR_IE, 0xFF); // déclenche interrupt_blocked=1

    cpu.servicePendingInterrupt(); // consommé par la période de blocage
    try testing.expectEqual(@as(u16, 0x0000), cpu.pc);
    try testing.expectEqual(Cpu.T0CNT_T0LOVF | Cpu.T0CNT_T0LIE, cpu.sfr_raw[Cpu.SFR_T0CNT]);

    cpu.servicePendingInterrupt(); // servi au cycle suivant
    try testing.expectEqual(@as(u16, 0x0013), cpu.pc);
}

test "RETI : retour + réautorisation avec skip libevmu" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0x13] = 0xB0; // RETI (opcode 0xB0) à l'entrée de l'ISR int2
    cpu.sfr_raw[Cpu.SFR_T0CNT] = Cpu.T0CNT_T0LOVF | Cpu.T0CNT_T0LIE;

    cpu.servicePendingInterrupt(); // entre dans l'ISR (retour prévu à 0x0000)
    try testing.expectEqual(@as(u16, 0x0013), cpu.pc);

    _ = step(&cpu); // RETI : pop PC, depth=0 ; le dispatch de fin de step
    // consomme lui-même le skip post-RETI libevmu (process_this_instr).
    try testing.expectEqual(@as(u16, 0x0000), cpu.pc);
    try testing.expectEqual(@as(u8, 0), cpu.interrupt_depth);

    cpu.sfr_raw[Cpu.SFR_T0CNT] |= Cpu.T0CNT_T0LOVF; // IRQ re-pendante immédiatement

    // depth=0 et process réarmé : la prochaine invocation sert directement.
    cpu.servicePendingInterrupt();
    try testing.expectEqual(@as(u16, 0x0013), cpu.pc);
}

test "IRQ : p3 derrière les timers, maple derrière p3" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    cpu.sfr_raw[Cpu.SFR_T0CNT] = Cpu.T0CNT_T0LOVF | Cpu.T0CNT_T0LIE;
    cpu.sfr_raw[Cpu.SFR_P3INT] = Cpu.P3INT_P30INT | Cpu.P3INT_P31INT;
    cpu.maple_irq_pending = true;

    cpu.servicePendingInterrupt(); // timer d'abord
    try testing.expectEqual(@as(u16, 0x0013), cpu.pc);

    allowNextIrq(&cpu);
    cpu.sfr_raw[Cpu.SFR_T0CNT] = 0; // plus de source timer
    cpu.servicePendingInterrupt(); // p3 ensuite
    try testing.expectEqual(@as(u16, 0x004B), cpu.pc);
    try testing.expectEqual(Cpu.P3INT_P31INT, cpu.sfr_raw[Cpu.SFR_P3INT] & Cpu.P3INT_P31INT); // source maintenue

    // L'ISR doit effacer P31INT elle-même, sinon p3 est resservie en boucle.
    cpu.sfr_raw[Cpu.SFR_P3INT] &= ~Cpu.P3INT_P31INT;
    allowNextIrq(&cpu);
    cpu.servicePendingInterrupt(); // maple en dernier
    try testing.expectEqual(@as(u16, 0x0043), cpu.pc);
    try testing.expect(!cpu.maple_irq_pending);
}

test "Timer 0 Mode 0 : overflow T0L, reload et flag" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // Prescaler : période = 256 - T0PRR (= 1 cycle, comme libevmu tscale=256-T0PRR).
    cpu.sfr_raw[Cpu.SFR_T0PRR] = 0xFF;
    cpu.sfr_raw[Cpu.SFR_T0LR] = 0x10;
    cpu.t0l_counter = 0xFE;
    cpu.sfr_raw[Cpu.SFR_T0CNT] = Cpu.T0CNT_T0LRUN;

    cpu.tickTimers(1);
    try testing.expectEqual(@as(u8, 0xFF), cpu.t0l_counter);
    try testing.expectEqual(@as(u8, 0), cpu.sfr_raw[Cpu.SFR_T0CNT] & Cpu.T0CNT_T0LOVF);

    cpu.tickTimers(1);
    try testing.expectEqual(@as(u8, 0x10), cpu.t0l_counter); // reload depuis T0LR
    try testing.expectEqual(Cpu.T0CNT_T0LOVF, cpu.sfr_raw[Cpu.SFR_T0CNT] & Cpu.T0CNT_T0LOVF);
}

test "Timer 0 Mode 0 : T0H indépendant de T0L" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    cpu.sfr_raw[Cpu.SFR_T0PRR] = 0xFF;
    cpu.sfr_raw[Cpu.SFR_T0HR] = 0x05;
    cpu.t0h_counter = 0xFF;
    cpu.t0l_counter = 0x42;
    cpu.sfr_raw[Cpu.SFR_T0CNT] = Cpu.T0CNT_T0HRUN; // T0L arrêté

    cpu.tickTimers(1);
    try testing.expectEqual(@as(u8, 0x05), cpu.t0h_counter); // overflow + reload
    try testing.expectEqual(Cpu.T0CNT_T0HOVF, cpu.sfr_raw[Cpu.SFR_T0CNT] & Cpu.T0CNT_T0HOVF);
    try testing.expectEqual(@as(u8, 0x42), cpu.t0l_counter); // intact
}

test "Timer 0 Mode 0 : écriture T0CNT sans RUN recharge depuis T0LR/T0HR" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    cpu.t0l_counter = 0x99;
    cpu.sfr_raw[Cpu.SFR_T0LR] = 0x11;
    cpu.t0h_counter = 0x88;
    cpu.sfr_raw[Cpu.SFR_T0HR] = 0x22;

    cpu.storeSFR(Cpu.SFR_T0CNT, 0); // aucun bit RUN → reload des deux compteurs

    try testing.expectEqual(@as(u8, 0x11), cpu.t0l_counter);
    try testing.expectEqual(@as(u8, 0x22), cpu.t0h_counter);
}

test "HALT : entrée PCON puis réveil par interruption Timer 0" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // Prescaler à période 1 pour que l'overflow arrive en 2 cycles.
    cpu.sfr_raw[Cpu.SFR_T0PRR] = 0xFF;
    cpu.sfr_raw[Cpu.SFR_T0LR] = 0xFE;
    cpu.t0l_counter = 0xFE;
    cpu.sfr_raw[Cpu.SFR_T0CNT] = Cpu.T0CNT_T0LRUN | Cpu.T0CNT_T0LIE;
    // MOV #01H,PCON (espace SFR : opcode 0x23) → halt pendant le step.
    // Avec un prescaler à période 1, l'overflow peut survenir dès ce même step
    // (2 cycles) : on ne suppose donc pas halted ici.
    rom[0] = 0x23; rom[1] = 0x07; rom[2] = 0x01;

    _ = step(&cpu);

    var n: usize = 0;
    while (cpu.halted and n < 100) : (n += 1) _ = step(&cpu);
    try testing.expect(!cpu.halted); // réveillé par l'IRQ int2 (libevmu : HALT bit de PCON effacé au service)
    try testing.expectEqual(@as(u16, 0x0013), cpu.pc); // ISR directement
    try testing.expectEqual(@as(u8, 1), cpu.interrupt_depth);
    try testing.expectEqual(@as(u8, 0), cpu.sfr_raw[Cpu.SFR_T0CNT] & Cpu.T0CNT_T0LOVF);
}

test "HALT : réveil par interruption P3 (vecteur 0x004B)" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // Sémantique libevmu : bouton pressé + P32INT → P31INT posé ; P30INT → IRQ servie.
    cpu.sfr_raw[Cpu.SFR_P3INT] = Cpu.P3INT_P32INT | Cpu.P3INT_P31INT | Cpu.P3INT_P30INT;
    cpu.halted = true;

    var n: usize = 0;
    while (cpu.halted and n < 100) : (n += 1) _ = step(&cpu);

    try testing.expect(!cpu.halted); // réveillé par l'IRQ p3
    try testing.expectEqual(@as(u16, 0x004B), cpu.pc); // ISR directement
    try testing.expectEqual(@as(u8, 1), cpu.interrupt_depth);
    try testing.expectEqual(Cpu.P3INT_P31INT, cpu.sfr_raw[Cpu.SFR_P3INT] & Cpu.P3INT_P31INT); // source maintenue
}

// ══════════════════════════════════════════════════════════════════
// Couverture des instructions non testées (doc_inst.md « À faire »)
// ══════════════════════════════════════════════════════════════════

test "NOP : avance PC de 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x00;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 1), cpu.pc);
}

test "BR : branchement relatif signé" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // BR +3 : PC_fetch2=2, +3 → PC=5
    rom[0] = 0x01;
    rom[1] = 0x03;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 5), cpu.pc);
    // BR -5 : PC_fetch2=0x0009, -5 → PC=0x0004
    cpu.pc = 7;
    rom[7] = 0x01;
    rom[8] = 0xFB; // -5
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 4), cpu.pc);
}

test "BRF : branchement relatif lointain" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // BRF offset=0x0010 : PC_fetch3=3, +0x000F → PC=0x0012
    rom[0] = 0x11;
    rom[1] = 0x10;
    rom[2] = 0x00;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 0x0012), cpu.pc);
    // Retour arrière : offset=0xFFF0 (-16) : PC_fetch3=0x0023, +0xFFEF → PC=0x0012
    cpu.pc = 0x0020;
    rom[0x0020] = 0x11;
    rom[0x0021] = 0xF0;
    rom[0x0022] = 0xFF;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 0x0012), cpu.pc);
}

test "BNZ : branchement si ACC ≠ 0" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // BNZ +3 avec ACC=1 → branch
    rom[0] = 0x90;
    rom[1] = 0x03;
    cpu.a = 1;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 5), cpu.pc);
    // BNZ +3 avec ACC=0 → pas de branch
    cpu.pc = 2;
    cpu.a = 0;
    rom[2] = 0x90;
    rom[3] = 0x03;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 4), cpu.pc);
}

test "MUL VMC-170 : multiplication ACC:C × B" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x30;
    rom[1] = 0x30;
    // Ex1 : 0x1123 × 0x52 = 0x057D36 → B=05, ACC=7D, C=36, CY=0, OV=1
    cpu.a = 0x11;
    cpu.c = 0x23;
    cpu.b = 0x52;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x7D), cpu.a);
    try testing.expectEqual(@as(u8, 0x36), cpu.c);
    try testing.expectEqual(@as(u8, 0x05), cpu.b);
    try testing.expect(!cpu.psw.cy);
    try testing.expect(cpu.psw.ov);
    // Ex2 : 0x0705 × 0x10 = 0x007050 → B=00, ACC=70, C=50, CY=0, OV=0
    cpu.a = 0x07;
    cpu.c = 0x05;
    cpu.b = 0x10;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x70), cpu.a);
    try testing.expectEqual(@as(u8, 0x50), cpu.c);
    try testing.expectEqual(@as(u8, 0x00), cpu.b);
    try testing.expect(!cpu.psw.cy);
    try testing.expect(!cpu.psw.ov);
}

test "DIV VMC-171 : division ACC:C / B" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x40;
    rom[1] = 0x40;
    // Ex1 : 0x7905 / 0x07 = 0x1149 r 6 → ACC=11, C=49, B=06, CY=0, OV=0
    cpu.a = 0x79;
    cpu.c = 0x05;
    cpu.b = 0x07;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x11), cpu.a);
    try testing.expectEqual(@as(u8, 0x49), cpu.c);
    try testing.expectEqual(@as(u8, 0x06), cpu.b);
    try testing.expect(!cpu.psw.cy);
    try testing.expect(!cpu.psw.ov);
    // Ex2 : B=0 → ACC=FF, OV=1
    cpu.a = 0x07;
    cpu.c = 0x10;
    cpu.b = 0x00;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0xFF), cpu.a);
    try testing.expect(!cpu.psw.cy);
    try testing.expect(cpu.psw.ov);
}

test "BE #i8 : branchement si ACC = immédiat" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // Égal → branch, CY=0
    rom[0] = 0x31;
    rom[1] = 0x02;
    rom[2] = 0x01;
    cpu.a = 0x02;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 4), cpu.pc);
    try testing.expect(!cpu.psw.cy);
    // Inégal (ACC < i8) → pas branch, CY=1
    rom[4] = 0x31;
    rom[5] = 0x04;
    rom[6] = 0x01;
    cpu.pc = 4;
    cpu.a = 0x03;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 7), cpu.pc);
    try testing.expect(cpu.psw.cy);
}

test "BE d9 : branchement si ACC = direct" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // BE B, +1 : 0x33 → d8=1, d9=0x102 (SFR_B) → ACC=B → branch
    rom[0] = 0x33;
    rom[1] = 0x02;
    rom[2] = 0x01;
    cpu.a = 0x05;
    cpu.b = 0x05;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 4), cpu.pc);
    try testing.expect(!cpu.psw.cy);
    // ACC < B → CY=1, pas branch
    rom[4] = 0x33;
    rom[5] = 0x02;
    rom[6] = 0x01;
    cpu.pc = 4;
    cpu.a = 0x03;
    cpu.b = 0xF2;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 7), cpu.pc);
    try testing.expect(cpu.psw.cy);
}

test "BE @Ri : branchement si ACC = indirect" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // BE @R0, +1 : ACC = RAM[RAM[0]] → branch
    rom[0] = 0x34;
    rom[1] = 0x01;
    cpu.ram_bank0[0] = 0x10;
    cpu.ram_bank0[0x10] = 0x05;
    cpu.a = 0x05;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 3), cpu.pc);
    // Pas branch
    rom[3] = 0x34;
    rom[4] = 0x01;
    cpu.pc = 3;
    cpu.a = 0x06;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 5), cpu.pc);
}

test "BNE #i8 : branchement si ACC ≠ immédiat" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // ACC ≠ i8 → branch
    rom[0] = 0x41;
    rom[1] = 0x00;
    rom[2] = 0x01;
    cpu.a = 0x02;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 4), cpu.pc);
    try testing.expect(!cpu.psw.cy);
    // ACC = i8 → pas branch
    rom[4] = 0x41;
    rom[5] = 0x03;
    rom[6] = 0x01;
    cpu.pc = 4;
    cpu.a = 0x03;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 7), cpu.pc);
}

test "BNE d9 : branchement si ACC ≠ direct" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // ACC < B → branch, CY=1 — 0x43 → d8=1, d9=0x102 (SFR_B)
    rom[0] = 0x43;
    rom[1] = 0x02;
    rom[2] = 0x01;
    cpu.a = 0x02;
    cpu.b = 0x03;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 4), cpu.pc);
    try testing.expect(cpu.psw.cy);
    // ACC = B → pas branch, CY=0
    rom[4] = 0x43;
    rom[5] = 0x02;
    rom[6] = 0x01;
    cpu.pc = 4;
    cpu.a = 0xF2;
    cpu.b = 0xF2;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 7), cpu.pc);
    try testing.expect(!cpu.psw.cy);
}

test "BNE @Ri : branchement si ACC ≠ indirect" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // ACC = RAM[@R0] → pas branch
    rom[0] = 0x44;
    rom[1] = 0x01;
    cpu.ram_bank0[0] = 0x10;
    cpu.ram_bank0[0x10] = 0xF2;
    cpu.a = 0xF2;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 2), cpu.pc);
    // ACC ≠ RAM[@R0] → branch
    rom[2] = 0x44;
    rom[3] = 0x01;
    cpu.pc = 2;
    cpu.a = 0x00;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 5), cpu.pc);
}

test "BP d9,b3 : branchement si bit = 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // BP ACC,0,+1 → 0x78 → d8=1, bit=0 → ACC.0=1 → branch
    rom[0] = 0x78;
    rom[1] = 0x00;
    rom[2] = 0x01;
    cpu.a = 0x01;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 4), cpu.pc);
    // BP ACC,7,+1 → 0x7F → d8=1, bit=7 → ACC.7=0 → pas branch
    rom[4] = 0x7F;
    rom[5] = 0x00;
    rom[6] = 0x01;
    cpu.pc = 4;
    cpu.a = 0x01;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 7), cpu.pc);
}

test "BN d9,b3 : branchement si bit = 0" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // BN ACC,1,+1 → 0x99 → d8=1, bit=1 → ACC.1=0 → branch
    rom[0] = 0x99;
    rom[1] = 0x00;
    rom[2] = 0x01;
    cpu.a = 0x00;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 4), cpu.pc);
    // BN ACC,1,+1 → ACC.1=1 → pas branch
    rom[4] = 0x99;
    rom[5] = 0x00;
    rom[6] = 0x01;
    cpu.pc = 4;
    cpu.a = 0x02;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 7), cpu.pc);
}

test "SET1/CLR1/NOT1 : manipulation de bits" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // SET1 ACC,7 → 0xFF → d8=1, bit=7 → ACC |= 0x80
    rom[0] = 0xFF;
    rom[1] = 0x00;
    cpu.a = 0x00;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x80), cpu.a);
    // CLR1 ACC,7 → 0xDF → d8=1, bit=7 → ACC &= ~0x80
    rom[2] = 0xDF;
    rom[3] = 0x00;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x00), cpu.a);
    // NOT1 ACC,7 → 0xBF → d8=1, bit=7 → toggle bit 7
    rom[4] = 0xBF;
    rom[5] = 0x00;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x80), cpu.a);
    // SET1 07FH,6 → 0xEE → d8=0, bit=6 → RAM[0x7F] |= 0x40
    rom[6] = 0xEE;
    rom[7] = 0x7F;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x40), cpu.ram_bank0[0x7F]);
    // CLR1 07FH,6 → 0xCE → d8=0, bit=6
    rom[8] = 0xCE;
    rom[9] = 0x7F;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x00), cpu.ram_bank0[0x7F]);
}

test "DEC @Ri : décrémentation indirecte" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x74; // DEC @R0 (not 0x64 = INC @R0)
    rom[1] = 0x74;
    rom[2] = 0x74;
    cpu.ram_bank0[0] = 0x10;
    cpu.ram_bank0[0x10] = 0x02;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x01), cpu.ram_bank0[0x10]);
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x00), cpu.ram_bank0[0x10]);
    _ = step(&cpu); // wrap 0x00→0xFF
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x10]);
}

test "ADDC @Ri : addition avec retenue indirecte" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x94; // ADDC @R0
    rom[1] = 0x94;
    rom[2] = 0x94;
    cpu.ram_bank0[0] = 0x10;
    cpu.ram_bank0[0x10] = 0x03;
    // Sans retenue
    cpu.a = 0x05;
    cpu.psw.cy = false;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x08), cpu.a);
    try testing.expect(!cpu.psw.cy);
    // Débordement → CY=1
    cpu.a = 0xFF;
    cpu.psw.cy = false;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x02), cpu.a);
    try testing.expect(cpu.psw.cy);
    // Avec retenue : 0x02 + 0x03 + 1 = 0x06
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x06), cpu.a);
    try testing.expect(!cpu.psw.cy);
}

test "DBNZ d9 : décrémentation directe et branchement" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // DBNZ B,+1 → 0x53 → d8=1, d9=0x102 (SFR_B) : B=2→1, nonzero → branch
    rom[0] = 0x53;
    rom[1] = 0x02;
    rom[2] = 0x01;
    cpu.b = 0x02;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x01), cpu.b);
    try testing.expectEqual(@as(u16, 4), cpu.pc);
    // DBNZ B,+1 : B=1→0, zero → pas branch
    rom[4] = 0x53;
    rom[5] = 0x02;
    rom[6] = 0x01;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x00), cpu.b);
    try testing.expectEqual(@as(u16, 7), cpu.pc);
}

test "DBNZ @Ri : décrémentation indirecte et branchement" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // DBNZ @R0,+1 : ram[0x10]=2→1, nonzero → branch to PC=3
    rom[0] = 0x54;
    rom[1] = 0x01;
    rom[2] = 0x00; // padding
    rom[3] = 0x54;
    rom[4] = 0x01;
    cpu.ram_bank0[0] = 0x10;
    cpu.ram_bank0[0x10] = 0x02;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x01), cpu.ram_bank0[0x10]);
    try testing.expectEqual(@as(u16, 3), cpu.pc);
    // RAM[0x10]=1→0, zero → pas branch
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x00), cpu.ram_bank0[0x10]);
    try testing.expectEqual(@as(u16, 5), cpu.pc);
}

test "LDC VMC-191 : chargement depuis ROM (table)" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0xC1; // LDC
    rom[1] = 0xC1;
    rom[2] = 0xC1;
    cpu.trh = 0x01;
    cpu.trl = 0x23; // TRR = 0x0123
    // ACC=0 → ROM[0x0123]
    cpu.a = 0x00;
    rom[0x0123] = 0x30;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x30), cpu.a);
    // ACC=1 → ROM[0x0124]
    cpu.a = 0x01;
    rom[0x0124] = 0xFF;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0xFF), cpu.a);
    // ACC=2 → ROM[0x0125]
    cpu.a = 0x02;
    rom[0x0125] = 0x57;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x57), cpu.a);
}
