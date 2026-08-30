// Préparation de l'image VMU et de l'état attendu par le BIOS.
//
// Extrait de main.zig pour être testable sans hôte ni raylib (AD-7).
// Mise en forme du système de fichiers flash identique à DreamPotato ;
// initialisation BIOS/RTC identique à libevmu (EvmuRam_IBehavior_reset_).

const Cpu = @import("lc86K").Cpu;

/// Initialize VMU flash with a proper filesystem (same layout as DreamPotato).
/// Flash = 128KB = 256 blocks × 512 bytes.
/// Blocks 0-199: user data, 200-240: hidden, 241-253: directory, 254: FAT, 255: root.
pub fn initVmuFlash(cpu: *Cpu) void {
    const flash = &cpu.flash;
    // Erased flash is 0xFF
    @memset(flash, 0xFF);

    // --- Root block (block 255, offset 0x1FE00) ---
    const rb: usize = 255 * 512;
    // Magic 0x55 at 0x00-0x0F
    for (0..16) |i| flash[rb + i] = 0x55;
    // VolumeLast at 0x40
    flash[rb + 0x40] = 0xFF;
    flash[rb + 0x41] = 0xFF;
    // Partition at 0x42
    flash[rb + 0x42] = 0x00;
    flash[rb + 0x43] = 0x00;
    // Root at 0x44
    flash[rb + 0x44] = 0xFF;
    flash[rb + 0x45] = 0x00;
    // FATFirst at 0x46
    flash[rb + 0x46] = 0xFE;
    flash[rb + 0x47] = 0x00;
    // FATSize at 0x48
    flash[rb + 0x48] = 0x01;
    flash[rb + 0x49] = 0x00;
    // DirLast at 0x4A
    flash[rb + 0x4A] = 0xFD;
    flash[rb + 0x4B] = 0x00;
    // DirSize at 0x4C
    flash[rb + 0x4C] = 0x0D;
    flash[rb + 0x4D] = 0x00;
    // Icon at 0x4E
    flash[rb + 0x4E] = 0x00;
    // Sort at 0x4F
    flash[rb + 0x4F] = 0x00;
    // HiddenFirst at 0x50
    flash[rb + 0x50] = 0xC8;
    flash[rb + 0x51] = 0x00;
    // HiddenSize at 0x52
    flash[rb + 0x52] = 0x29;
    flash[rb + 0x53] = 0x00;
    // GameFirst at 0x54
    flash[rb + 0x54] = 0x00;
    flash[rb + 0x55] = 0x00;
    // GameSize at 0x56 (128 blocks = 65536 / 512)
    flash[rb + 0x56] = 0x80;
    flash[rb + 0x57] = 0x00;

    // --- FAT (block 254, offset 0x1FC00) ---
    const fb: usize = 254 * 512;
    // All entries start as 0xFF (unallocated), already set by memset
    // Mark root block as FAT_LastInFile
    flash[fb + 255 * 2] = 0xFA;
    flash[fb + 255 * 2 + 1] = 0xFF;
    // Mark FAT block itself as FAT_LastInFile
    flash[fb + 254 * 2] = 0xFA;
    flash[fb + 254 * 2 + 1] = 0xFF;
    // Directory chain: block 253 → 252 → ... → 241 → FAT_LastInFile
    {
        var i: u16 = 253;
        while (i > 241) : (i -= 1) {
            flash[fb + i * 2] = @intCast(i - 1);
            flash[fb + i * 2 + 1] = 0x00;
        }
        flash[fb + 241 * 2] = 0xFA;
        flash[fb + 241 * 2 + 1] = 0xFF;
    }

    // Directory table (blocks 241-253) is already 0xFF → all entries Type=0x00 (None)
}

/// Create the directory entry for the game at directory table (block 253,
/// entry 0) and set up its FAT chain (block 0 → 1 → ... → FAT_LastInFile).
/// The caller must have loaded the game image into flash blocks 0..N first.
pub fn installGame(cpu: *Cpu, game_size: usize) void {
    const flash = &cpu.flash;
    const dir_base = 253 * 512;
    flash[dir_base + 0x00] = 0xCC; // FileType = Game
    flash[dir_base + 0x01] = 0x80; // CopyProtection = not copy protected
    flash[dir_base + 0x02] = 0x00; // StartFAT low = 0
    flash[dir_base + 0x03] = 0x00; // StartFAT high = 0
    // Filename: 12 bytes at offset 0x04 (padded with 0)
    const game_name = "GAME";
    for (game_name, 0..) |ch, idx| {
        flash[dir_base + 0x04 + idx] = ch;
    }
    // SizeInBlocks at 0x18
    const size_blocks: u16 = @intCast((game_size + 511) / 512);
    flash[dir_base + 0x18] = @truncate(size_blocks);
    flash[dir_base + 0x19] = @truncate(size_blocks >> 8);
    // VmsHeaderBlockOffset at 0x1A (header is at block 0)
    flash[dir_base + 0x1A] = 0x00;
    flash[dir_base + 0x1B] = 0x00;

    // Set up FAT chain for game blocks (block 0 → 1 → 2 → ... → FAT_LastInFile)
    const fat_base: usize = 254 * 512;
    const last_game_block: u16 = @intCast((game_size + 511) / 512 - 1);
    {
        var b: u16 = 0;
        while (b <= last_game_block) : (b += 1) {
            const fat_off: usize = fat_base + @as(usize, b) * 2;
            if (b == last_game_block) {
                flash[fat_off] = 0xFA; // FAT_LastInFile low
                flash[fat_off + 1] = 0xFF; // FAT_LastInFile high
            } else {
                flash[fat_off] = @truncate(b + 1); // next block low
                flash[fat_off + 1] = 0x00; // next block high
            }
        }
    }
}

/// Initialize BIOS date and SFRs to match libevmu's EvmuRam_IBehavior_reset_().
/// Sets PC to 0x2E1 to skip the Dreamcast serial date query (we don't emulate the serial link).
/// Writes date to RAM and configures SFRs the BIOS expects at startup.
pub fn initBiosRtc(cpu: *Cpu) void {
    // Jump past the BIOS serial date-query code (no Dreamcast serial emulation)
    cpu.pc = 0x2E1;
    // Write current date to RAM bank 0 (BCD format + binary)
    // Same addresses as EvmuRom_setDateTime() in evmu_rom.c
    cpu.ram_bank0[0x10] = 0x20; // Century BCD (20)
    cpu.ram_bank0[0x11] = 0x26; // Year BCD (26)
    cpu.ram_bank0[0x12] = 0x07; // Month BCD (07)
    cpu.ram_bank0[0x13] = 0x17; // Day BCD (17)
    cpu.ram_bank0[0x14] = 0x12; // Hour BCD (12)
    cpu.ram_bank0[0x15] = 0x30; // Minute BCD (30)
    cpu.ram_bank0[0x16] = 0x00; // Second BCD (00)
    cpu.ram_bank0[0x17] = 0x00; // Year MSB
    cpu.ram_bank0[0x18] = 0x07; // Year LSB (2026 = 0x07EA)
    cpu.ram_bank0[0x19] = 0x07; // Month (binary)
    cpu.ram_bank0[0x1A] = 0x17; // Day (binary)
    cpu.ram_bank0[0x1B] = 0x12; // Hour (binary)
    cpu.ram_bank0[0x1C] = 0x30; // Minute (binary)
    cpu.ram_bank0[0x1D] = 0x00; // Second (binary)
    cpu.ram_bank0[0x1E] = 0; // HalfSecond
    cpu.ram_bank0[0x1F] = 0; // LeapYear
    // DateTime_DateSet at 0x31 = 0xFF means "date is set" (evmu_address_space.h)
    cpu.ram_bank0[0x31] = 0xFF;

    // SFR initialization matching libevmu's EvmuRam_IBehavior_reset_() in evmu_ram.c
    cpu.sfr_raw[Cpu.SFR_PCON] = 0x00; // PCON: disable HALT/HOLD
    cpu.sfr_raw[Cpu.SFR_IE] = 0xFF; // IE: all interrupts enabled (EA=1 + all individual)
    cpu.sfr_raw[Cpu.SFR_IP] = 0x00; // IP: no priority (default)
    cpu.sfr_raw[Cpu.SFR_OCR] = 0xA3; // OCR: quartz selected (10), RC stopped (1), CF stopped (1), /6 (1)
    cpu.sfr_raw[Cpu.SFR_MCR] = 0x08; // MCR: LCD update enable (bit3)
    cpu.sfr_raw[Cpu.SFR_VCCR] = 0x80; // VCCR: LCD on (bit7)
    cpu.sfr_raw[Cpu.SFR_P1DDR] = 0xFF; // P1DDR: all output
    cpu.sfr_raw[Cpu.SFR_P1FCR] = 0xBF; // P1FCR: port 1 function control
    cpu.sfr_raw[Cpu.SFR_P3DDR] = 0x00; // P3DDR: all input
    cpu.sfr_raw[Cpu.SFR_P3INT] = 0xFD; // P3INT: P30INT=1 (enable), P31INT=0, P32INT=1 (continuous)
    cpu.sfr_raw[Cpu.SFR_P7] = 0x02; // P7: P71 mask
    cpu.sfr_raw[Cpu.SFR_ISL] = 0xC0; // ISL: base timer clock = quartz oscillator
    cpu.sfr_raw[Cpu.SFR_VSEL] = 0xFC; // VSEL: default value
    cpu.sfr_raw[Cpu.SFR_BTCR] = 0x41; // BTCR: BT_INT0_SRC=quartz, BT_INT0_IE=1
}
