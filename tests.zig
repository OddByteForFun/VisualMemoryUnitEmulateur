const std = @import("std");
const testing = std.testing;
const Cpu = @import("lc86K").Cpu;
const step = @import("decode").step;

fn makeCpu(rom: []u8) Cpu {
    @memset(rom, 0);
    return Cpu.init(rom);
}

test "nop advances PC by 1" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x00; // nop
    try testing.expectEqual(@as(u16, 0), cpu.pc);
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 1), cpu.pc);
}

test "BR forward" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x01; // br
    rom[1] = 0x3f; // +63
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 0x41), cpu.pc);
}

test "BR backward" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    cpu.pc = 0x10;
    rom[0x10] = 0x01; // br
    rom[0x11] = 0xFE; // -2
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 0x10), cpu.pc);
}

test "BZ taken when ACC zero" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x80; // bz
    rom[1] = 0x05; // +5
    cpu.a = 0;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 7), cpu.pc);
}

test "BZ not taken when ACC non-zero" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x80; // bz
    rom[1] = 0x05;
    cpu.a = 1;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 2), cpu.pc);
}

test "BNZ taken when ACC non-zero" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x90; // bnz
    rom[1] = 0x05;
    cpu.a = 1;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 7), cpu.pc);
}

test "BNZ not taken when ACC zero" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x90; // bnz
    rom[1] = 0x05;
    cpu.a = 0;
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 2), cpu.pc);
}

test "BN branches when memory bit clear" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // BN d9=0x10, bit=0, r8=0x05
    // opcode 0x88 = row 8 col 8 → bn, mode .d9, bit=(opcode&7=0)
    rom[0] = 0x88; // BN with d9 bit0=0
    rom[1] = 0x10; // d9 byte → address = (0&1)<<8 | 0x10 = 0x10
    rom[2] = 0x05; // +5
    cpu.store8(0x10, 0x00); // bit 0 is 0 → branch taken
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 8), cpu.pc); // 3 + 5
}

test "BN not taken when memory bit set" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x88;
    rom[1] = 0x10;
    rom[2] = 0x05;
    cpu.store8(0x10, 0x01); // bit 0 is 1 → branch not taken
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 3), cpu.pc);
}

test "ADD immediate" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x81; // add #imm
    rom[1] = 42;
    try testing.expectEqual(@as(u8, 0), cpu.a);
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 2), cpu.pc);
    try testing.expectEqual(@as(u8, 42), cpu.a);
}

test "ADD immediate carry" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x81; // add #200
    rom[1] = 200;
    cpu.a = 200;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 144), cpu.a);
    try testing.expect(cpu.psw.cy);
}

test "ADD immediate overflow" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x81;
    rom[1] = 0x81;
    rom[2] = 0x81;
    rom[3] = 0x81;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x81), cpu.a);
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x02), cpu.a);
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

test "OR direct" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0xD2; rom[1] = 0x23;
    rom[2] = 0xD2; rom[3] = 0x23;
    cpu.a = 0x00;
    cpu.ram_bank0[0x23] = 0x55;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x55), cpu.a);
    cpu.ram_bank0[0x23] = 0xAA;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFF), cpu.a);
}

test "XOR immediate" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0xF1; rom[1] = 0xFF;
    cpu.a = 0x55;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xAA), cpu.a);
}

test "ROL 0x01 → 0x02" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0xE0;
    cpu.a = 0x01;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x02), cpu.a);
}

test "ROL wraps MSB to LSB" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0xE0;
    cpu.a = 0x80;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x01), cpu.a);
}

test "ROL 8 times returns to original (0x55 ↔ 0xAA)" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    @memset(&rom, 0xE0);
    cpu.a = 0x55;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xAA), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x55), cpu.a);
}

test "ROR 0x01 → 0x80" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0xC0;
    cpu.a = 0x01;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x80), cpu.a);
}

test "ROR wraps LSB to MSB" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0xC0;
    rom[1] = 0xC0;
    rom[2] = 0xC0;
    cpu.a = 0x01;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x80), cpu.a);
    cpu.a = 0x51;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xA8), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x54), cpu.a);
}

test "ROLC through carry" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    @memset(&rom, 0xF0);
    cpu.a = 1;
    cpu.psw.cy = true;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b11), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b110), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b1100), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b11000), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b110000), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b1100000), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b11000000), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b10000000), cpu.a);
    try testing.expect(cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 1), cpu.a);
    try testing.expect(cpu.psw.cy);
}

test "RORC through carry" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    @memset(&rom, 0xD0);
    cpu.a = 0x01;
    cpu.psw.cy = true;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b10000000), cpu.a);
    try testing.expect(cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b11000000), cpu.a);
    try testing.expect(!cpu.psw.cy);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b01100000), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b00110000), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b00011000), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b00001100), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b00000110), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b00000011), cpu.a);
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0b00000001), cpu.a);
    try testing.expect(cpu.psw.cy);
}

test "MUL 0x1123 × 0x52 = 0x057D36" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x30;
    cpu.a = 0x11;
    cpu.c = 0x23;
    cpu.b = 0x52;
    try testing.expectEqual(@as(u8, 7), step(&cpu));
    try testing.expectEqual(@as(u8, 0x05), cpu.b);
    try testing.expectEqual(@as(u8, 0x7D), cpu.a);
    try testing.expectEqual(@as(u8, 0x36), cpu.c);
    try testing.expect(!cpu.psw.cy);
    try testing.expect(cpu.psw.ov);
}

test "MUL 0x0705 × 0x10 = 0x007050" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x30;
    cpu.a = 0x07;
    cpu.c = 0x05;
    cpu.b = 0x10;
    try testing.expectEqual(@as(u8, 7), step(&cpu));
    try testing.expectEqual(@as(u8, 0x00), cpu.b);
    try testing.expectEqual(@as(u8, 0x70), cpu.a);
    try testing.expectEqual(@as(u8, 0x50), cpu.c);
    try testing.expect(!cpu.psw.cy);
    try testing.expect(!cpu.psw.ov);
}

test "DIV 0x7905 ÷ 0x07 = 0x1149 rem 0x06" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x40;
    cpu.a = 0x79;
    cpu.c = 0x05;
    cpu.b = 0x07;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x06), cpu.b);
    try testing.expectEqual(@as(u8, 0x11), cpu.a);
    try testing.expectEqual(@as(u8, 0x49), cpu.c);
    try testing.expect(!cpu.psw.cy);
    try testing.expect(!cpu.psw.ov);
}

test "DIV by zero sets Ov and ACC=0xFF" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x40;
    cpu.a = 0x07;
    cpu.c = 0x10;
    cpu.b = 0x00;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0xFF), cpu.a);
    try testing.expectEqual(@as(u8, 0x10), cpu.c);
    try testing.expect(cpu.psw.ov);
    try testing.expect(!cpu.psw.cy);
}

test "INC direct memory" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x62; rom[1] = 0x7f;
    rom[2] = 0x62; rom[3] = 0x7f;
    rom[4] = 0x62; rom[5] = 0x7f;
    rom[6] = 0x62; rom[7] = 0x7f;
    cpu.ram_bank0[0x7f] = 0xFD;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0xFE), cpu.ram_bank0[0x7f]);
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x7f]);
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x00), cpu.ram_bank0[0x7f]);
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x01), cpu.ram_bank0[0x7f]);
}

test "DEC direct memory" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x72; rom[1] = 0x7f;
    rom[2] = 0x72; rom[3] = 0x7f;
    rom[4] = 0x72; rom[5] = 0x7f;
    cpu.ram_bank0[0x7f] = 0x02;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x01), cpu.ram_bank0[0x7f]);
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x00), cpu.ram_bank0[0x7f]);
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x7f]);
}

test "LD direct loads from memory into ACC" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x02; rom[1] = 0x70;
    cpu.ram_bank0[0x70] = 0x55;
    cpu.a = 0xFF;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x55), cpu.a);
}

test "ST direct stores ACC to memory" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x12; rom[1] = 0x70;
    cpu.a = 0xFF;
    cpu.ram_bank0[0x70] = 0x55;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x70]);
}

test "XCH direct swaps ACC and memory" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0xC2; rom[1] = 0x23;
    cpu.a = 0xFF;
    cpu.ram_bank0[0x23] = 0x55;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x55), cpu.a);
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x23]);
}

test "PUSH ACC onto stack" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // PUSH ACC: d9 pour SFR ACC (0x100) → opcode bit0=1 → 0x61, byte=0x00
    rom[0] = 0x61; rom[1] = 0x00; // opcode row 6 col 1, d9 byte=0x00 → addr = 0x100 = ACC
    cpu.sp = 0x1F;
    cpu.a = 0xAA;
    // On synchronise manuellement sfr_raw[0x00] = cpu.a pour que load8(0x100) → loadSFR → sfr_raw[0]
    // TODO: supprimer quand loadSFR sera synchronisé avec cpu.a
    cpu.sfr_raw[0x00] = 0xAA;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x20), cpu.sp);
    try testing.expectEqual(@as(u8, 0xAA), cpu.ram_bank0[0x20]);
}

test "POP from stack" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // POP ACC: d9 pour SFR ACC (0x100) → opcode bit0=1 → 0x71, byte=0x00
    rom[0] = 0x71; rom[1] = 0x00;
    cpu.sp = 0x20;
    cpu.ram_bank0[0x20] = 0x55;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x1F), cpu.sp);
    // store8(0x100) → storeSFR(0x00) → sfr_raw[0x00] = 0x55
    // TODO: utiliser cpu.a directement quand storeSFR synchro avec cpu.a
    try testing.expectEqual(@as(u8, 0x55), cpu.sfr_raw[0x00]);
}

test "CALL (call_a12) pushes return address and jumps" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // call_a12 at 0x0FFA: opcode 0x0F (row 0 col 0xF)
    rom[0x0FFA] = 0x0F; // call_a12
    rom[0x0FFB] = 0x0E; // imm8
    // A12 = (opcode&0x10)<<7 | (opcode&7)<<8 | imm8
    // = 0 | 7<<8 | 0x0E = 0x070E
    // PC = (PC & 0xF000) | A12
    cpu.pc = 0x0FFA;
    cpu.sp = 0x1F;
    _ = step(&cpu);
    // After step: pc = (0x0FFC & 0xF000) | 0x070E = 0x070E
    // SP after push low(0x20) + push high(0x21) = 0x21
    try testing.expectEqual(@as(u16, 0x070E), cpu.pc);
    try testing.expectEqual(@as(u8, 0x21), cpu.sp);
    try testing.expectEqual(@as(u8, 0xFC), cpu.ram_bank0[0x20]); // return_addr low
    try testing.expectEqual(@as(u8, 0x0F), cpu.ram_bank0[0x21]); // return_addr high
}

test "CALLR pushes return address and jumps relative" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0x0FFA] = 0x10; // callr
    rom[0x0FFB] = 0x01; // lo byte
    rom[0x0FFC] = 0x01; // hi byte → offset = 0x0101
    cpu.pc = 0x0FFA;
    cpu.sp = 0x1F;
    _ = step(&cpu);
    // PC after fetch: 0x0FFD. PC = 0x0FFD + 0x0101 - 1 = 0x10FD
    try testing.expectEqual(@as(u16, 0x10FD), cpu.pc);
    try testing.expectEqual(@as(u8, 0x21), cpu.sp);
    try testing.expectEqual(@as(u8, 0xFD), cpu.ram_bank0[0x20]); // return_addr low
    try testing.expectEqual(@as(u8, 0x0F), cpu.ram_bank0[0x21]); // return_addr high
}

test "BP branches when bit is set in memory" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x68; rom[1] = 0x10; rom[2] = 0x3F;
    cpu.ram_bank0[0x10] = 0x01; // bit 0 set
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 0x42), cpu.pc);
}

test "BP does not branch when bit is clear" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x68; rom[1] = 0x10; rom[2] = 0x3F;
    cpu.ram_bank0[0x10] = 0x00; // bit 0 clear
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 3), cpu.pc);
}

test "BP with bit 2" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x6A; rom[1] = 0x10; rom[2] = 0x3F;
    cpu.ram_bank0[0x10] = 0x04; // bit 2 set
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 0x42), cpu.pc);
}

test "step returns correct cycle counts" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x00; // nop → 1
    rom[1] = 0x81; rom[2] = 42; // add #imm → 1
    rom[3] = 0x30; // mul → 7
    rom[4] = 0x40; // div → 7
    rom[5] = 0xC0; // ror → 1
    try testing.expectEqual(@as(u8, 1), step(&cpu));
    try testing.expectEqual(@as(u8, 1), step(&cpu));
    try testing.expectEqual(@as(u8, 7), step(&cpu));
    try testing.expectEqual(@as(u8, 7), step(&cpu));
    try testing.expectEqual(@as(u8, 1), step(&cpu));
}

test "MOV #SP, CALLF, INC ACC, RET sequence" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);

    // MOV #0x1F,SP at 0FF9H: 23 06 1F
    rom[0xFF9] = 0x23;
    rom[0xFFA] = 0x06;
    rom[0xFFB] = 0x1F;

    // CALLF 0F0EH at 0FFCH: 20 0F 0E
    rom[0xFFC] = 0x20;
    rom[0xFFD] = 0x0F;
    rom[0xFFE] = 0x0E;

    // INC ACC at 0F0EH: 63 00
    rom[0xF0E] = 0x63;
    rom[0xF0F] = 0x00;

    // RET at 0F10H: A0
    rom[0xF10] = 0xA0;

    // NOP at 0FFFH: 00
    rom[0xFFF] = 0x00;

    cpu.pc = 0xFF9;
    cpu.a = 0xFF;

    _ = step(&cpu); // MOV #0x1F,SP
    try testing.expectEqual(@as(u8, 0x1F), cpu.sp);
    try testing.expectEqual(@as(u16, 0xFFC), cpu.pc);

    _ = step(&cpu); // CALLF 0F0EH
    try testing.expectEqual(@as(u16, 0xF0E), cpu.pc);
    try testing.expectEqual(@as(u8, 0x21), cpu.sp);
    try testing.expectEqual(@as(u8, 0xFF), cpu.ram_bank0[0x20]);
    try testing.expectEqual(@as(u8, 0x0F), cpu.ram_bank0[0x21]);

    _ = step(&cpu); // INC ACC
    try testing.expectEqual(@as(u8, 0x00), cpu.a);
    try testing.expectEqual(@as(u16, 0xF10), cpu.pc);

    _ = step(&cpu); // RET
    try testing.expectEqual(@as(u16, 0xFFF), cpu.pc);
    try testing.expectEqual(@as(u8, 0x1F), cpu.sp);

    _ = step(&cpu); // NOP
    try testing.expectEqual(@as(u16, 0x1000), cpu.pc);
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
    // SET1 PSW,7: 0xEF 0x01  (0xEF = row E col F → set1, bit=7, d9 addr = (1)<<8 | 0x01 = 0x101 = PSW)
    // ADDC 023H: 0x92 0x23
    rom[0] = 0x23; rom[1] = 0x00; rom[2] = 0x55;
    rom[3] = 0x22; rom[4] = 0x23; rom[5] = 0x68;
    rom[6] = 0x81; rom[7] = 0x0C;
    rom[8] = 0x92; rom[9] = 0x23;
    rom[10] = 0xEF; rom[11] = 0x01; // SET1 PSW,7 → CY=1
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

test "SET1 bit operation" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // SET1 010H,2: opcode 0xEA (row E col A, bit=2 even → d8=0 → RAM), d9_byte=0x10
    rom[0] = 0xEA; rom[1] = 0x10;
    // RAM[0x10] = 0
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x04), cpu.ram_bank0[0x10]);
}

test "CLR1 bit operation" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    cpu.ram_bank0[0x10] = 0xFF;
    // CLR1 010H,2: opcode 0xCA (row C col A, bit=2 even → d8=0 → RAM), d9_byte=0x10
    rom[0] = 0xCA; rom[1] = 0x10;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0xFB), cpu.ram_bank0[0x10]);
}

test "NOT1 bit operation" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    cpu.ram_bank0[0x10] = 0x00;
    // NOT1 010H,2: opcode 0xAA (row A col A, bit=2 even → d8=0 → RAM), d9_byte=0x10
    rom[0] = 0xAA; rom[1] = 0x10;
    _ = step(&cpu); try testing.expectEqual(@as(u8, 0x04), cpu.ram_bank0[0x10]);
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

test "RETI basic test" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    // Setup stack as if a CALL pushed return addr: SP points to hi byte
    cpu.sp = 0x21;
    cpu.ram_bank0[0x20] = 0x34; // lo (pushed first)
    cpu.ram_bank0[0x21] = 0x12; // hi (pushed last, SP points here)
    cpu.pc = 0x10;
    rom[0x10] = 0xB0; // RETI
    _ = step(&cpu);
    try testing.expectEqual(@as(u16, 0x1234), cpu.pc);
    try testing.expectEqual(@as(u8, 0x1F), cpu.sp);
}

test "BRF forward" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0xF1C] = 0x00; rom[0xF1D] = 0x00; // NOPs
    rom[0xF1E] = 0x11; // BRF
    rom[0xF1F] = 0x3F; // lo
    rom[0xF20] = 0x01; // hi → offset=0x013F
    rom[0x105F] = 0x63; rom[0x1060] = 0x00; // INC ACC (LA=105FH)
    cpu.pc = 0xF1C;
    _ = step(&cpu);
    _ = step(&cpu);
    _ = step(&cpu);
    // PC after fetch = 0xF21. offset=0x013F. PC = 0xF21 + 0x013F - 1 = 0x105F
    try testing.expectEqual(@as(u16, 0x105F), cpu.pc);
}
