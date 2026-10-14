// Préparation de l'image VMU et de l'état attendu par le BIOS.
//
// Extrait de main.zig pour être testable sans hôte ni raylib (AD-7).
// Mise en forme du système de fichiers flash identique à DreamPotato ;
// initialisation BIOS/RTC identique à libevmu (EvmuRam_IBehavior_reset_).

const Cpu = @import("lc86K").Cpu;

/// Initialize VMU flash with a proper filesystem (same layout as DreamPotato).
/// Flash = 128KB = 256 blocks × 512 bytes.
pub fn initVmuFlash(cpu: *Cpu) void {
    const flash = &cpu.flash;
    // Erased flash is 0xFF
    // @memset(flash, 0xFF);

    // --- Root block (block 255, offset 0x1FE00) ---
    // taille globale soir 256*512 = 128 Kb
    // 0x000 - 0 x0c7 données utilisateur
    // 0x0c8 - 0x0f8 zone reservée
    // 0x0f1 - 0x0fd repertoire
    // 0x0fe FAT
    // 0x0ff Root

    // 0xFFFC = bloc libre
    // 0xFFFA = fin de chaîne
    // 0xFFFF = bloc défectueux

    const rb: usize = 255 * 512; // rootblock

    // https://www.elysianshadows.com/vmu/filesystem.html
    // https://kos-docs.dreamcast.wiki/structvmu__dir__t.html#details
    // il s'agit de commencer par le root bloc :
    //    offset  taille  champ
    // --------------------------------
    // 0x00    16      Magic
    // 0x10    32      Volume Label
    // 0x30     8      Timestamp
    // 0x40     2      VolumeLast (255)
    // 0x42     2      Partition (0)
    // 0x44     2      Root (255)
    // 0x46     2      FATFirst (254)
    // 0x48     2      FATSize (1)
    // 0x4A     2      DirLast (253)
    // 0x4C     2      DirSize (13)
    // 0x4E     1      Icon (0-123)
    // 0x4F     1      Sort (0)
    // 0x50     2      HiddenFirst (200)
    // 0x52     2      HiddenSize (31)
    // 0x54     2      GameFirst (0)
    // 0x56     2      GameSize (128)
    // tout le reste est reservé
    // Magic 0x55 at 0x00-0x0F
    // Le directory occupe de 253 à 241 soit 13 blocs

    for (0..16) |i| flash[rb + i] = 0x55; // magic
    // Volume label / color
    flash[rb + 0x10] = 0x00; // standard color
    flash[rb + 0x11] = 0x00;
    flash[rb + 0x12] = 0x00;
    flash[rb + 0x13] = 0x00;
    flash[rb + 0x14] = 0x00;

    // Reserved
    @memset(flash[rb + 0x15 .. rb + 0x30], 0);
    // Reserved
    @memset(flash[rb + 0x38 .. rb + 0x40], 0);

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
    flash[rb + 0x52] = 0x1F; // 200
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
    // 0xFFFC = Unallocated / Free
    // 0xFFFF = Damaged
    // 0xFFFA = Last in file
    // Mark root block as FAT_LastInFile

    // cela remplit la flash avec 0xFFFC

    for (0..256) |i| {
        flash[fb + i * 2] = 0xFC;
        flash[fb + i * 2 + 1] = 0xFF;
    }

    flash[fb + 255 * 2] = 0xFA;
    flash[fb + 255 * 2 + 1] = 0xFF;
    // Mark FAT block itself as FAT_LastInFile
    flash[fb + 254 * 2] = 0xFA;
    flash[fb + 254 * 2 + 1] = 0xFF;
    // Directory chain: block 253 → 252 → ... → 241 → FAT_LastInFile
    {
        var i: usize = 253;
        while (i > 241) : (i -= 1) {
            flash[fb + i * 2] = @intCast(i - 1);
            flash[fb + i * 2 + 1] = 0x00;
        }
        flash[fb + 241 * 2] = 0xFA;
        flash[fb + 241 * 2 + 1] = 0xFF;
    }

    // Directory table (blocks 241-253) is already 0xFF → all entries Type=0x00 (None)
    @memset(flash[241 * 512 .. 254 * 512], 0x00);
}

pub const VmsInfo = struct {
    file_type: u8 = 0xCC, // 0xCC = Game, 0x33 = Data
    copy_protect: u8 = 0x80, // 0x80 = not protected, 0x00 = protected
    filename: [12]u8 = "GAME        ".*,
    size_blocks: u16 = 0,
    header_offset: u16 = 1, // 1 for Game, 0 for Data
    vmu_desc: [16]u8 = [_]u8{' '} ** 16,
    dc_desc: [32]u8 = [_]u8{' '} ** 32,
    app_id: [16]u8 = [_]u8{' '} ** 16,
    icon_count: u16 = 1,
};

fn isValidVmsHeader(hdr: []const u8) bool {
    if (hdr.len < 0x58) return false;
    const icon_count = @as(u16, hdr[0x40]) | (@as(u16, hdr[0x41]) << 8);
    const eyecatch = @as(u16, hdr[0x44]) | (@as(u16, hdr[0x45]) << 8);
    if (icon_count > 3 or eyecatch > 3) return false;
    // Les octets réservés à 0x4C..0x58 doivent être nuls dans un en-tête VMS officiel
    for (hdr[0x4C..0x58]) |b| {
        if (b != 0) return false;
    }
    return true;
}

/// Analyse un fichier VMS (et son fichier VMI optionnel) pour extraire les métadonnées officielles.
pub fn parseVms(vms_data: []const u8, maybe_vmi_data: ?[]const u8) VmsInfo {
    var info = VmsInfo{
        .size_blocks = @intCast((vms_data.len + 511) / 512),
    };

    // 1. Si un fichier .VMI est fourni (descripteur sidecar de 108 octets)
    if (maybe_vmi_data) |vmi| {
        if (vmi.len >= 108) {
            // Type de fichier à 0x64 (0 = DATA, autre = GAME)
            const vmi_type = @as(u16, vmi[0x64]) | (@as(u16, vmi[0x65]) << 8);
            if (vmi_type == 0) {
                info.file_type = 0x33;
                info.header_offset = 0;
            } else {
                info.file_type = 0xCC;
                info.header_offset = 1;
            }

            // Protection copie à 0x66 (1 = protégé, 0 = non protégé)
            if (vmi[0x66] != 0) {
                info.copy_protect = 0x00;
            }

            // Nom de fichier flash à 0x58 (12 octets)
            var has_name = false;
            for (vmi[0x58..0x64]) |c| {
                if (c != 0 and c != ' ') {
                    has_name = true;
                    break;
                }
            }
            if (has_name) {
                @memcpy(&info.filename, vmi[0x58..0x64]);
            }
        }
    } else {
        // Détection automatique GAME vs DATA si pas de .vmi
        if (vms_data.len >= 0x280 and isValidVmsHeader(vms_data[0x200..0x280])) {
            info.file_type = 0xCC;
            info.header_offset = 1;
        } else if (vms_data.len >= 0x80 and isValidVmsHeader(vms_data[0x00..0x80])) {
            info.file_type = 0x33;
            info.header_offset = 0;
        }
    }

    // 2. Détection et extraction de l'en-tête VMS dans vms_data
    var header_slice: ?[]const u8 = null;

    if (vms_data.len >= 0x280 and info.header_offset == 1) {
        // En-tête à 0x200 (GAME)
        header_slice = vms_data[0x200..0x280];
    } else if (vms_data.len >= 0x80) {
        // En-tête à 0x000 (DATA ou fallback)
        header_slice = vms_data[0x00..0x80];
    }

    if (header_slice) |hdr| {
        @memcpy(&info.vmu_desc, hdr[0x00..0x10]);
        @memcpy(&info.dc_desc, hdr[0x10..0x30]);
        @memcpy(&info.app_id, hdr[0x30..0x40]);
        info.icon_count = @as(u16, hdr[0x40]) | (@as(u16, hdr[0x41]) << 8);

        // Si le nom de fichier n'a pas été fourni par un .VMI, le dériver de vmu_desc
        if (maybe_vmi_data == null) {
            var valid_chars: usize = 0;
            for (info.vmu_desc, 0..) |c, idx| {
                if (idx >= 12) break;
                if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-') {
                    info.filename[idx] = c;
                    valid_chars += 1;
                } else if (valid_chars > 0 and idx < 12) {
                    info.filename[idx] = ' ';
                }
            }
            if (valid_chars == 0) {
                @memcpy(&info.filename, "GAME        ");
            }
        }
    }

    return info;
}

/// Installe un fichier VMS dans la flash avec son entrée de répertoire et sa chaîne FAT
pub fn installVms(cpu: *Cpu, info: VmsInfo, vms_data: []const u8) void {
    const flash = &cpu.flash;
    const copy_len = @min(vms_data.len, 65536);
    if (flash[0..copy_len].ptr != vms_data[0..copy_len].ptr) {
        @memcpy(flash[0..copy_len], vms_data[0..copy_len]);
    }

    const dir_base = 253 * 512;
    flash[dir_base + 0x00] = info.file_type;
    flash[dir_base + 0x01] = info.copy_protect;
    flash[dir_base + 0x02] = 0x00; // StartFAT low = 0
    flash[dir_base + 0x03] = 0x00; // StartFAT high = 0

    // Nom de fichier : 12 octets à l'offset 0x04
    @memcpy(flash[dir_base + 0x04 .. dir_base + 0x10], &info.filename);

    // Timestamp à l'offset 0x10 (format BCD)
    flash[dir_base + 0x10] = 0x20; // Siècle (20)
    flash[dir_base + 0x11] = 0x26; // Année (26)
    flash[dir_base + 0x12] = 0x07; // Mois (07)
    flash[dir_base + 0x13] = 0x17; // Jour (17)
    flash[dir_base + 0x14] = 0x12; // Heure (12)
    flash[dir_base + 0x15] = 0x30; // Minute (30)
    flash[dir_base + 0x16] = 0x00; // Seconde (00)
    flash[dir_base + 0x17] = 0x00; // Jour de la semaine

    // Taille en blocs à l'offset 0x18
    flash[dir_base + 0x18] = @truncate(info.size_blocks);
    flash[dir_base + 0x19] = @truncate(info.size_blocks >> 8);

    // Offset de l'en-tête VMS en blocs à l'offset 0x1A
    flash[dir_base + 0x1A] = @truncate(info.header_offset);
    flash[dir_base + 0x1B] = @truncate(info.header_offset >> 8);

    @memset(flash[dir_base + 0x1C .. dir_base + 0x20], 0x00);

    // Chaîne FAT pour les blocs du fichier (0 -> 1 -> ... -> FAT_LastInFile)
    const fat_base: usize = 254 * 512;
    const last_block: u16 = if (info.size_blocks > 0) info.size_blocks - 1 else 0;
    var b: u16 = 0;
    while (b <= last_block) : (b += 1) {
        const fat_off: usize = fat_base + @as(usize, b) * 2;
        if (b == last_block) {
            flash[fat_off] = 0xFA; // FAT_LastInFile low
            flash[fat_off + 1] = 0xFF; // FAT_LastInFile high
        } else {
            flash[fat_off] = @truncate(b + 1);
            flash[fat_off + 1] = 0x00;
        }
    }
}

pub fn installGame(cpu: *Cpu, game_size: usize) void {
    var info = VmsInfo{
        .size_blocks = @intCast((game_size + 511) / 512),
    };
    @memcpy(&info.filename, "GAME        ");
    installVms(cpu, info, cpu.flash[0..game_size]);
}

/// Initialize BIOS date and SFRs to match libevmu's EvmuRam_IBehavior_reset_().
/// Sets PC to 0x2E1 to skip the Dreamcast serial date query (we don't emulate the serial link).
/// Writes date to RAM and configures SFRs the BIOS expects at startup.
pub fn initBiosRtc(cpu: *Cpu, bios_menu_mode: bool, set_time_mode: bool) void {
    if (set_time_mode) {
        // Démarre à l'entrée de la configuration manuelle de la date du BIOS (0x02AF)
        cpu.pc = 0x02AF;
        cpu.ram_bank0[0x31] = 0x00; // 0x00 = date non configurée -> affiche l'écran de réglage officiel
    } else {
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
    }

    // Initialiser les boutons à l'état relâché (active-low = 0xFF pour P3, active-high = 0x00 pour RAM 0x70)
    cpu.p3_buttons = 0xFF;
    // En mode menu, aucun bouton n'est enfoncé (0x00) -> le BIOS reste dans le menu
    // En mode auto-launch direct, simuler le bouton A (0x10) pour lancer le jeu immédiatement
    cpu.ram_bank0[0x70] = if (bios_menu_mode) 0x00 else 0x10;
    cpu.ram_bank0[0x71] = 0x00;
    cpu.ram_bank0[0x72] = 0x00;

    // SFR initialization matching libevmu's EvmuRam_IBehavior_reset_() in evmu_ram.c
    cpu.sfr_raw[Cpu.SFR_PCON] = 0x00; // PCON: disable HALT/HOLD
    cpu.sfr_raw[Cpu.SFR_IE] = 0xFF; // IE: all interrupts enabled (EA=1 + all individual)
    cpu.sfr_raw[Cpu.SFR_IP] = 0x00; // IP: no priority (default)
    // OCR: en standalone, démarrer en RC/12 (~73kHz) comme le vrai VMU.
    // En Dreamcast, l'horloge externe 6MHz prime, donc OCR n'a pas d'impact.
    cpu.sfr_raw[Cpu.SFR_OCR] = if (cpu.dreamcast_connected) 0xA3 else 0x03;
    cpu.sfr_raw[Cpu.SFR_MCR] = 0x08; // MCR: LCD update enable (bit3)
    cpu.sfr_raw[Cpu.SFR_VCCR] = 0x80; // VCCR: LCD on (bit7)
    cpu.sfr_raw[Cpu.SFR_P1DDR] = 0xFF; // P1DDR: all output
    cpu.sfr_raw[Cpu.SFR_P1FCR] = 0xBF; // P1FCR: port 1 function control
    cpu.sfr_raw[Cpu.SFR_P3DDR] = 0x00; // P3DDR: all input
    cpu.sfr_raw[Cpu.SFR_P3INT] = 0xFD; // P3INT: P30INT=1 (enable), P31INT=0, P32INT=1 (continuous)
    cpu.sfr_raw[Cpu.SFR_P7] = if (bios_menu_mode) 0x02 else 0x00; // P7: bit1=0 => standalone/auto-launch, bit1=1 => menu/normal BIOS path
    cpu.sfr_raw[Cpu.SFR_ISL] = 0xC0; // ISL: base timer clock = quartz oscillator
    cpu.sfr_raw[Cpu.SFR_VSEL] = 0xFC; // VSEL: default value
    cpu.sfr_raw[Cpu.SFR_BTCR] = 0x41; // BTCR: BT_INT0_SRC=quartz, BT_INT0_IE=1
}
