// Table ISA unifiée du Sanyo LC86K87.
//
// Source unique de vérité pour l'encodage des 256 opcodes : instruction,
// mode d'adressage, taille en octets, cycles, mnémonique et forme
// d'affichage. Consommée par decode.zig (exécution) et debug.zig
// (désassemblage, dimensionnement).
//
// Références : doc/VMU.pdf, https://mc.pp.se/dc/vms/cpu.html

pub const AddressingMode = enum(u2) {
    impl,
    imm,
    d9,
    ri,
};

pub const Inst = enum(u8) {
    nop,
    br,
    ld,
    ld_ri,
    call_a12,
    callr,
    brf,
    st,
    st_ri,
    callf,
    jmpf,
    mov,
    mov_ri,
    jmp_a12,
    mul,
    be_imm,
    be_d9,
    be_ri,
    div,
    bne_imm,
    bne_d9,
    bne_ri,
    bpc,
    dbnz_d9,
    dbnz_ri,
    push,
    inc_d9,
    inc_ri,
    bp,
    pop,
    dec_d9,
    dec_ri,
    bz,
    add_imm,
    add_d9,
    add_ri,
    bn,
    bnz,
    addc_imm,
    addc_d9,
    addc_ri,
    ret,
    sub_imm,
    sub_d9,
    sub_ri,
    not1,
    reti,
    subc_imm,
    subc_d9,
    subc_ri,
    ror,
    ldc,
    ldf,
    stf,
    xch_d9,
    xch_ri,
    clr1,
    rorc,
    or_imm,
    or_d9,
    or_ri,
    rol,
    and_imm,
    and_d9,
    and_ri,
    set1,
    rolc,
    xor_imm,
    xor_d9,
    xor_ri,
};

// Formes d'affichage du désassembleur ; les noms reprennent les helpers
// historiques de debug.zig (fmtI, fmtA…) pour faciliter la lecture.
// Plusieurs variantes fmtA_* partagent la même sortie "xxxxh" mais se
// distinguent par le calcul de la cible.
pub const DispForm = enum {
    fmtI, // pas d'opérande affichée : NOP, MUL, RET, BZ…
    fmtI2, // valeur brute sur 16 bits : BRF
    fmtImm, // "#xxh" : ALU immédiates
    fmtBI, // "#xxh" : BE/BNE immédiates
    fmtA_d9, // adresse directe d9 : LD/ST/INC/PUSH…
    fmtA_br, // cible relative 8 bits : PC + 2 + rel8
    fmtA_callr, // cible CALLR : PC + 3 + off16
    fmtA_jmp, // cible page CALL/JMP a12 : (PC & F000h) | ad12
    fmtA_abs, // adresse absolue hi:lo : CALLF/JMPF
    fmtR, // "@Rj"
    fmtM, // "xxxxh,#xxh"
    fmtMR, // "@Rj,#xxh"
    fmtBitBranch, // "xxxh.b" : BP/BN/BPC
    fmtBitOp, // "xxxh.b" : NOT1/CLR1/SET1
};

pub const IsaEntry = struct {
    inst: Inst,
    mode: AddressingMode = .impl,
    size: u16,
    cycles: u8,
    mnemonic: []const u8,
    disp: DispForm,
    ri: ?u8 = null,
    bit: ?u8 = null,

    /// Opcode complet (rempli à la génération de TABLE).
    opcode: u8 = 0,
};

fn buildEntry(opcode: u8) IsaEntry {
    const row: u4 = @truncate(opcode >> 4);
    const col: u4 = @truncate(opcode);
    var e: IsaEntry = switch (row) {
        0x0 => switch (col) {
            0x0 => .{ .inst = .nop, .size = 1, .cycles = 1, .mnemonic = "NOP", .disp = .fmtI },
            0x1 => .{ .inst = .br, .mode = .imm, .size = 2, .cycles = 2, .mnemonic = "BR", .disp = .fmtA_br },
            0x2...0x3 => .{ .inst = .ld, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "LD", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .ld_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "LD", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .call_a12, .mode = .imm, .size = 2, .cycles = 2, .mnemonic = "CALL", .disp = .fmtA_jmp },
        },
        0x1 => switch (col) {
            0x0 => .{ .inst = .callr, .mode = .imm, .size = 3, .cycles = 4, .mnemonic = "CALLR", .disp = .fmtA_callr },
            // Le décodeur consomme un offset 16 bits (fetch16) : 3 octets.
            // L'ancienne table du désassembleur annonçait 2 (bug corrigé).
            0x1 => .{ .inst = .brf, .mode = .imm, .size = 3, .cycles = 4, .mnemonic = "BRF", .disp = .fmtI2 },
            0x2...0x3 => .{ .inst = .st, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "ST", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .st_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "ST", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .call_a12, .mode = .imm, .size = 2, .cycles = 2, .mnemonic = "CALL", .disp = .fmtA_jmp },
        },
        0x2 => switch (col) {
            0x0 => .{ .inst = .callf, .mode = .imm, .size = 3, .cycles = 2, .mnemonic = "CALLF", .disp = .fmtA_abs },
            0x1 => .{ .inst = .jmpf, .mode = .imm, .size = 3, .cycles = 2, .mnemonic = "JMPF", .disp = .fmtA_abs },
            0x2...0x3 => .{ .inst = .mov, .mode = .d9, .size = 3, .cycles = 2, .mnemonic = "MOV", .disp = .fmtM },
            0x4...0x7 => .{ .inst = .mov_ri, .mode = .ri, .size = 2, .cycles = 1, .mnemonic = "MOV", .disp = .fmtMR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .jmp_a12, .mode = .imm, .size = 2, .cycles = 2, .mnemonic = "JMP", .disp = .fmtA_jmp },
        },
        0x3 => switch (col) {
            0x0 => .{ .inst = .mul, .size = 1, .cycles = 7, .mnemonic = "MUL", .disp = .fmtI },
            0x1 => .{ .inst = .be_imm, .mode = .imm, .size = 3, .cycles = 2, .mnemonic = "BE", .disp = .fmtBI },
            0x2...0x3 => .{ .inst = .be_d9, .mode = .d9, .size = 3, .cycles = 2, .mnemonic = "BE", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .be_ri, .mode = .ri, .size = 2, .cycles = 2, .mnemonic = "BE", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .jmp_a12, .mode = .imm, .size = 2, .cycles = 2, .mnemonic = "JMP", .disp = .fmtA_jmp },
        },
        0x4 => switch (col) {
            0x0 => .{ .inst = .div, .size = 1, .cycles = 7, .mnemonic = "DIV", .disp = .fmtI },
            0x1 => .{ .inst = .bne_imm, .mode = .imm, .size = 3, .cycles = 2, .mnemonic = "BNE", .disp = .fmtBI },
            0x2...0x3 => .{ .inst = .bne_d9, .mode = .d9, .size = 3, .cycles = 2, .mnemonic = "BNE", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .bne_ri, .mode = .ri, .size = 2, .cycles = 2, .mnemonic = "BNE", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .bpc, .mode = .d9, .size = 3, .cycles = 2, .mnemonic = "BPC", .disp = .fmtBitBranch, .bit = opcode & 0x7 },
        },
        0x5 => switch (col) {
            0x0 => .{ .inst = .ldf, .size = 1, .cycles = 2, .mnemonic = "LDF", .disp = .fmtI },
            0x1 => .{ .inst = .stf, .size = 1, .cycles = 2, .mnemonic = "STF", .disp = .fmtI },
            0x2...0x3 => .{ .inst = .dbnz_d9, .mode = .d9, .size = 3, .cycles = 2, .mnemonic = "DBNZ", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .dbnz_ri, .mode = .ri, .size = 2, .cycles = 2, .mnemonic = "DBNZ", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .bpc, .mode = .d9, .size = 3, .cycles = 2, .mnemonic = "BPC", .disp = .fmtBitBranch, .bit = opcode & 0x7 },
        },
        0x6 => switch (col) {
            0x0...0x1 => .{ .inst = .push, .mode = .d9, .size = 2, .cycles = 2, .mnemonic = "PUSH", .disp = .fmtA_d9 },
            0x2...0x3 => .{ .inst = .inc_d9, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "INC", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .inc_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "INC", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .bp, .mode = .d9, .size = 3, .cycles = 2, .mnemonic = "BP", .disp = .fmtBitBranch, .bit = opcode & 0x7 },
        },
        0x7 => switch (col) {
            0x0...0x1 => .{ .inst = .pop, .mode = .d9, .size = 2, .cycles = 2, .mnemonic = "POP", .disp = .fmtA_d9 },
            0x2...0x3 => .{ .inst = .dec_d9, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "DEC", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .dec_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "DEC", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .bp, .mode = .d9, .size = 3, .cycles = 2, .mnemonic = "BP", .disp = .fmtBitBranch, .bit = opcode & 0x7 },
        },
        0x8 => switch (col) {
            0x0 => .{ .inst = .bz, .mode = .imm, .size = 2, .cycles = 2, .mnemonic = "BZ", .disp = .fmtI },
            0x1 => .{ .inst = .add_imm, .mode = .imm, .size = 2, .cycles = 1, .mnemonic = "ADD", .disp = .fmtImm },
            0x2...0x3 => .{ .inst = .add_d9, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "ADD", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .add_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "ADD", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .bn, .mode = .d9, .size = 3, .cycles = 2, .mnemonic = "BN", .disp = .fmtBitBranch, .bit = opcode & 0x7 },
        },
        0x9 => switch (col) {
            0x0 => .{ .inst = .bnz, .mode = .imm, .size = 2, .cycles = 2, .mnemonic = "BNZ", .disp = .fmtI },
            0x1 => .{ .inst = .addc_imm, .mode = .imm, .size = 2, .cycles = 1, .mnemonic = "ADDC", .disp = .fmtImm },
            0x2...0x3 => .{ .inst = .addc_d9, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "ADDC", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .addc_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "ADDC", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .bn, .mode = .d9, .size = 3, .cycles = 2, .mnemonic = "BN", .disp = .fmtBitBranch, .bit = opcode & 0x7 },
        },
        0xA => switch (col) {
            0x0 => .{ .inst = .ret, .size = 1, .cycles = 2, .mnemonic = "RET", .disp = .fmtI },
            0x1 => .{ .inst = .sub_imm, .mode = .imm, .size = 2, .cycles = 1, .mnemonic = "SUB", .disp = .fmtImm },
            0x2...0x3 => .{ .inst = .sub_d9, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "SUB", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .sub_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "SUB", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .not1, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "NOT1", .disp = .fmtBitOp, .bit = opcode & 0x7 },
        },
        0xB => switch (col) {
            0x0 => .{ .inst = .reti, .size = 1, .cycles = 2, .mnemonic = "RETI", .disp = .fmtI },
            0x1 => .{ .inst = .subc_imm, .mode = .imm, .size = 2, .cycles = 1, .mnemonic = "SUBC", .disp = .fmtImm },
            0x2...0x3 => .{ .inst = .subc_d9, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "SUBC", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .subc_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "SUBC", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .not1, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "NOT1", .disp = .fmtBitOp, .bit = opcode & 0x7 },
        },
        0xC => switch (col) {
            0x0 => .{ .inst = .ror, .size = 1, .cycles = 1, .mnemonic = "ROR", .disp = .fmtI },
            0x1 => .{ .inst = .ldc, .size = 1, .cycles = 2, .mnemonic = "LDC", .disp = .fmtI },
            0x2...0x3 => .{ .inst = .xch_d9, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "XCH", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .xch_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "XCH", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .clr1, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "CLR1", .disp = .fmtBitOp, .bit = opcode & 0x7 },
        },
        0xD => switch (col) {
            0x0 => .{ .inst = .rorc, .size = 1, .cycles = 1, .mnemonic = "RORC", .disp = .fmtI },
            0x1 => .{ .inst = .or_imm, .mode = .imm, .size = 2, .cycles = 1, .mnemonic = "OR", .disp = .fmtImm },
            0x2...0x3 => .{ .inst = .or_d9, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "OR", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .or_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "OR", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .clr1, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "CLR1", .disp = .fmtBitOp, .bit = opcode & 0x7 },
        },
        0xE => switch (col) {
            0x0 => .{ .inst = .rol, .size = 1, .cycles = 1, .mnemonic = "ROL", .disp = .fmtI },
            0x1 => .{ .inst = .and_imm, .mode = .imm, .size = 2, .cycles = 1, .mnemonic = "AND", .disp = .fmtImm },
            0x2...0x3 => .{ .inst = .and_d9, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "AND", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .and_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "AND", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .set1, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "SET1", .disp = .fmtBitOp, .bit = opcode & 0x7 },
        },
        0xF => switch (col) {
            0x0 => .{ .inst = .rolc, .size = 1, .cycles = 1, .mnemonic = "ROLC", .disp = .fmtI },
            0x1 => .{ .inst = .xor_imm, .mode = .imm, .size = 2, .cycles = 1, .mnemonic = "XOR", .disp = .fmtImm },
            0x2...0x3 => .{ .inst = .xor_d9, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "XOR", .disp = .fmtA_d9 },
            0x4...0x7 => .{ .inst = .xor_ri, .mode = .ri, .size = 1, .cycles = 1, .mnemonic = "XOR", .disp = .fmtR, .ri = col & 0x3 },
            0x8...0xF => .{ .inst = .set1, .mode = .d9, .size = 2, .cycles = 1, .mnemonic = "SET1", .disp = .fmtBitOp, .bit = opcode & 0x7 },
        },
    };
    e.opcode = opcode;
    return e;
}

pub const TABLE: [256]IsaEntry = blk: {
    var t: [256]IsaEntry = undefined;
    for (0..256) |i| t[i] = buildEntry(@intCast(i));
    break :blk t;
};

pub fn entry(opcode: u8) *const IsaEntry {
    return &TABLE[opcode];
}

/// Décodage de l'adresse directe d9 depuis l'octet haut de l'opcode et
/// l'octet bas lu dans le flux (partagé par décodeur et désassembleur).
pub fn decodeD9(opcode: u8, val: u8) u16 {
    const d8: u16 = if (opcode & 0x08 != 0)
        @as(u16, opcode >> 4) & 1
    else
        @as(u16, opcode) & 1;
    return d8 << 8 | val;
}
