const std = @import("std");
const Cpu = @import("lc86K").Cpu;
const decode = @import("decode");
const step = decode.step;
const rl = @import("raylib");

const LCD_W = 48;
const LCD_H = 32;
const BYTES_PER_ROW: u32 = LCD_W / 8;
const SCALE: i32 = 10;
const FG = rl.Color.init(20, 20, 20, 255);
const BG = rl.Color.init(190, 210, 180, 255);

var azerty_mode: bool = false;
var bios_menu_mode_flag: bool = false;
var bios_menu_active: bool = false;
var bios_menu_selected: bool = false;
var bios_menu_index: u32 = 0;
var start_pulse_frames: u32 = 0;

pub fn main(init: std.process.Init) !void {
    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    defer arg_iter.deinit();
    _ = arg_iter.skip();

    var path_a: ?[]const u8 = null;
    var path_b: ?[]const u8 = null;

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--azerty")) {
            azerty_mode = true;
        } else if (std.mem.eql(u8, arg, "--bios-menu")) {
            bios_menu_mode_flag = true;
        } else if (path_a == null) {
            path_a = arg;
        } else if (path_b == null) {
            path_b = arg;
        }
    }

    _ = path_a orelse {
        std.debug.print("Usage: lc86K [<bios.bin>] <game.vms> [--azerty] [--bios-menu]\n", .{});
        return;
    };

    const use_bios_menu: bool = bios_menu_mode_flag or path_b != null;

    // 2 files: first=BIOS, second=game | 1 file: game only, BIOS auto-detected
    const bios_path: []const u8 = if (path_b != null) path_a.? else "roms/vmu_bios_jp.bin";
    const game_path: []const u8 = if (path_b) |b| b else path_a.?;

    const dir = std.Io.Dir.cwd();

    // Load BIOS into ROM (64KB padded)
    const bios_file = try dir.openFile(init.io, bios_path, .{});
    defer bios_file.close(init.io);

    const rom = init.arena.allocator().alloc(u8, 65536) catch unreachable;
    @memset(rom, 0);
    const bios_size = try bios_file.readPositionalAll(init.io, rom[0..65536], 0);
    std.debug.print("BIOS: {s} ({d} bytes)\n", .{ bios_path, bios_size });

    var cpu = Cpu.init(rom);

    // Initialize a proper VMU flash filesystem (same approach as DreamPotato)
    initVmuFlash(&cpu);

    // Load game into flash block 0 (inside the filesystem)
    const game_file = try dir.openFile(init.io, game_path, .{});
    defer game_file.close(init.io);

    const game_size = try game_file.readPositionalAll(init.io, cpu.flash[0..65536], 0);
    std.debug.print("Game: {s} ({d} bytes)\n", .{ game_path, game_size });

    // Create directory entry for the game at directory table (block 253, entry 0)
    const dir_base = 253 * 512;
    cpu.flash[dir_base + 0x00] = 0xCC; // FileType = Game
    cpu.flash[dir_base + 0x01] = 0x80; // CopyProtection = not copy protected
    cpu.flash[dir_base + 0x02] = 0x00; // StartFAT low = 0
    cpu.flash[dir_base + 0x03] = 0x00; // StartFAT high = 0
    // Filename: 12 bytes at offset 0x04 (padded with 0)
    const game_name = "GAME";
    for (game_name, 0..) |ch, idx| {
        cpu.flash[dir_base + 0x04 + idx] = ch;
    }
    // SizeInBlocks at 0x18
    const size_blocks: u16 = @intCast((game_size + 511) / 512);
    cpu.flash[dir_base + 0x18] = @truncate(size_blocks);
    cpu.flash[dir_base + 0x19] = @truncate(size_blocks >> 8);
    // VmsHeaderBlockOffset at 0x1A (header is at block 1)
    cpu.flash[dir_base + 0x1A] = 0x01;
    cpu.flash[dir_base + 0x1B] = 0x00;

    // Set up FAT chain for game blocks (block 0 → 1 → 2 → ... → FAT_LastInFile)
    const fat_base: usize = 254 * 512;
    const last_game_block: u16 = @intCast((game_size + 511) / 512 - 1);
    {
        var b: u16 = 0;
        while (b <= last_game_block) : (b += 1) {
            const fat_off: usize = fat_base + @as(usize, b) * 2;
            if (b == last_game_block) {
                cpu.flash[fat_off] = 0xFA; // FAT_LastInFile low
                cpu.flash[fat_off + 1] = 0xFF; // FAT_LastInFile high
            } else {
                cpu.flash[fat_off] = @truncate(b + 1); // next block low
                cpu.flash[fat_off + 1] = 0x00; // next block high
            }
        }
    }

    cpu.reset();

    // Initialize BIOS RTC (same as DreamPotato's InitializeRTCDate)
    // The BIOS checks DateTime_DateSet (RAM 0xFF) to decide if date is ready.
    // Without this, the BIOS waits forever for the Dreamcast to send the date.
    initBiosRtc(&cpu, use_bios_menu);

    if (use_bios_menu) {
        bios_menu_active = true;
        std.debug.print("BIOS menu mode enabled: P7=0x{X:0>2} (non-standalone => BIOS file menu path)\n", .{ cpu.sfr_raw[0x5C] });
    }

    const win_w: i32 = LCD_W * SCALE;
    const win_h: i32 = LCD_H * SCALE + 24 + SCALE + 8;
    rl.initWindow(win_w, win_h, "LC86K VMU Emulator");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var cycles: u64 = 0;
    var frames: u64 = 0;
    var prev_pc: u16 = 0;
    var stuck_count: u32 = 0;

    var prev_halted = false;

    while (!rl.windowShouldClose()) {
        // Poll input events BEFORE reading key state, so isKeyDown reflects current frame
        rl.pollInputEvents();
        updateButtons(&cpu);

        const cycles_per_frame: u64 = 100_000;
        var i: u64 = 0;
        while (i < cycles_per_frame) : (i += 1) {
            _ = step(&cpu);
            _ = cpu.checkBiosPhase();
            cycles += 1;

            if (cpu.halted != prev_halted) {
                prev_halted = cpu.halted;
            }

            if (cpu.halted) {
                stuck_count = 0;
                // The base timer runs on a 32.768kHz quartz oscillator that keeps
                // ticking even when the CPU is halted. Simulate the full frame's
                // worth of timer ticks so the base timer can fire INT3 and wake
                // the CPU from HALT.
                const remaining: u32 = @intCast(cycles_per_frame - i);
                var ticked: u32 = 0;
                while (ticked < remaining) {
                    const batch: u8 = @intCast(@min(remaining - ticked, 255));
                    cpu.tickTimers(batch);
                    ticked += batch;
                    cpu.requestLevelDrivenInterrupts();
                    cpu.servicePendingInterrupt();
                    if (!cpu.halted) {
                        break;
                    }
                }
                cycles += ticked;
                i = cycles_per_frame;
                break;
            }

            if (cpu.pc == prev_pc) {
                stuck_count += 1;
            } else {
                stuck_count = 0;
                prev_pc = cpu.pc;
            }
        }

        if (!bios_menu_selected and cpu.bios_phase == .bios_game_launch) {
            // Hardware-like transition: clear the full P3 latch before the game starts so no
            // stale BIOS MODE or Start state leaks into flash0 execution.
            cpu.p3_buttons = 0xFF;
            cpu.prev_p3_buttons = 0xFF;
            cpu.ram_bank0[0x70] = 0xFF;
            cpu.sfr_raw[0x4E] = 0xFD;
            cpu.setInstructionBank(.flash0);
            cpu.pc = 0x0000;
            bios_menu_selected = true;
            bios_menu_active = false;
            start_pulse_frames = 0;
        }

        rl.beginDrawing();
        rl.clearBackground(BG);
        if (bios_menu_active and !bios_menu_selected) {
            drawBiosMenuScreen(game_path);
        } else {
            renderLcd(&cpu);
        }

        var buf: [256]u8 = undefined;
        const status = std.fmt.bufPrintZ(&buf, "PC=0x{X:0>4} ext={X:0>2} sync={d} xram_wr={d}", .{ cpu.pc, cpu.pending_ext, cpu.sync_count, cpu.xram_write_count }) catch "??";
        rl.drawText(status, 4, win_h - 18, 14, rl.Color.white);

        rl.endDrawing();
        frames += 1;

    }
}

/// Initialize VMU flash with a libevmu-like filesystem layout.
/// Flash = 128KB = 256 blocks × 512 bytes.
/// Blocks 0-199: user data, 200-240: hidden, 241-253: directory, 254: FAT, 255: root.
fn initVmuFlash(cpu: *Cpu) void {
    const flash = &cpu.flash;
    @memset(flash, 0xFF);

    // Root block: 255, offset 0x1FE00.
    // Keep the metadata 16-bit little-endian fields in the exact layout expected by
    // the BIOS when scanning the VMU filesystem.
    const rb: usize = 255 * 512;
    for (0..16) |i| flash[rb + i] = 0x55;

    // VolumeLast at 0x40, 0xFFFF = no last volume in this unit
    flash[rb + 0x40] = 0xFF;
    flash[rb + 0x41] = 0xFF;

    // Partition at 0x42, 0x0000 = primary partition
    flash[rb + 0x42] = 0x00;
    flash[rb + 0x43] = 0x00;

    // Root at 0x44 (block 255)
    flash[rb + 0x44] = 0xFF;
    flash[rb + 0x45] = 0x00;

    // FATFirst at 0x46 (block 254)
    flash[rb + 0x46] = 0xFE;
    flash[rb + 0x47] = 0x00;

    // FATSize at 0x48 (1 block)
    flash[rb + 0x48] = 0x01;
    flash[rb + 0x49] = 0x00;

    // DirLast at 0x4A (block 253)
    flash[rb + 0x4A] = 0xFD;
    flash[rb + 0x4B] = 0x00;

    // DirSize at 0x4C (13 blocks: 241..253)
    flash[rb + 0x4C] = 0x0D;
    flash[rb + 0x4D] = 0x00;

    // Icon / Sort are unused for a normal game volume.
    flash[rb + 0x4E] = 0x00;
    flash[rb + 0x4F] = 0x00;

    // HiddenFirst/HiddenSize at 0x50/0x52 (blocks 200..240)
    flash[rb + 0x50] = 0xC8;
    flash[rb + 0x51] = 0x00;
    flash[rb + 0x52] = 0x29;
    flash[rb + 0x53] = 0x00;

    // GameFirst / GameSize at 0x54 / 0x56.
    // For a single GAME file starting at block 0, the size is 128 blocks = 65536 bytes.
    flash[rb + 0x54] = 0x00;
    flash[rb + 0x55] = 0x00;
    flash[rb + 0x56] = 0x80;
    flash[rb + 0x57] = 0x00;

    // FAT block 254.
    const fb: usize = 254 * 512;

    // Root block and FAT block terminate their own chains as EOF.
    flash[fb + 255 * 2] = 0xFA;
    flash[fb + 255 * 2 + 1] = 0xFF;
    flash[fb + 254 * 2] = 0xFA;
    flash[fb + 254 * 2 + 1] = 0xFF;

    // Directory chain: 253 -> 252 -> ... -> 241 -> FAT_LastInFile.
    {
        var i: u16 = 253;
        while (i > 241) : (i -= 1) {
            flash[fb + i * 2] = @intCast(i - 1);
            flash[fb + i * 2 + 1] = 0x00;
        }
        flash[fb + 241 * 2] = 0xFA;
        flash[fb + 241 * 2 + 1] = 0xFF;
    }

    // Free blocks are tagged 0xFCFF to match libevmu's FAT allocator behavior.
    // Only the blocks that are legitimately allocated for the directory and the game
    // remain in a non-free chain.
    for (0..256) |b| {
        const off: usize = fb + b * 2;
        if (flash[off] == 0xFF and flash[off + 1] == 0xFF) {
            flash[off] = 0xFC;
            flash[off + 1] = 0xFF;
        }
    }
}

/// Initialize BIOS date and SFRs to match libevmu's EvmuRam_IBehavior_reset_().
/// Sets PC to 0x2E1 to skip the Dreamcast serial date query (we don't emulate the serial link).
/// Writes date to RAM and configures SFRs the BIOS expects at startup.
fn initBiosRtc(cpu: *Cpu, bios_menu_mode: bool) void {
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
    cpu.sfr_raw[0x07] = 0x00; // PCON: disable HALT/HOLD
    cpu.sfr_raw[0x08] = 0xFF; // IE: all interrupts enabled (EA=1 + all individual)
    cpu.sfr_raw[0x09] = 0x00; // IP: no priority (default)
    cpu.sfr_raw[0x0E] = 0xA3; // OCR: quartz selected (10), RC stopped (1), CF stopped (1), /6 (1)
    cpu.sfr_raw[0x20] = 0x08; // MCR: LCD update enable (bit3)
    cpu.sfr_raw[0x27] = 0x80; // VCCR: LCD on (bit7)
    cpu.sfr_raw[0x45] = 0xFF; // P1DDR: all output
    cpu.sfr_raw[0x46] = 0xBF; // P1FCR: port 1 function control
    cpu.sfr_raw[0x4D] = 0x00; // P3DDR: all input
    cpu.sfr_raw[0x4E] = 0xFD; // P3INT: P30INT=1 + P32INT=1 => continuous button interrupt while held
    cpu.sfr_raw[0x5C] = if (bios_menu_mode) 0x02 else 0x00; // P7: bit1=0 => standalone/auto-launch, bit1=1 => menu/normal BIOS path
    cpu.sfr_raw[0x5F] = 0xC0; // ISL: base timer clock = quartz oscillator
    cpu.sfr_raw[0x63] = 0xFC; // VSEL: default value
    cpu.sfr_raw[0x7F] = 0x41; // BTCR: BT_INT0_SRC=quartz, BT_INT0_IE=1
}

fn drawBiosMenuScreen(game_path: []const u8) void {
    rl.clearBackground(rl.Color.black);
    rl.drawRectangle(0, 0, LCD_W * SCALE, LCD_H * SCALE, rl.Color.black);
    rl.drawText("SEGA", 8, 4, 14, rl.Color.white);
    rl.drawText("Visual Memory", 8, 20, 10, rl.Color.white);
    rl.drawText("---", 8, 30, 10, rl.Color.white);

    const name = if (std.mem.lastIndexOfScalar(u8, game_path, '/')) |idx| game_path[idx + 1 ..] else game_path;
    var y: i32 = 42;
    rl.drawText(">", 8, y, 10, rl.Color.white);
    var buf: [128:0]u8 = @splat(0);
    const label = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch "GAME";
    rl.drawText(label, 20, y, 10, rl.Color.white);

    y += 12;
    rl.drawText("MODE to launch", 8, y, 9, rl.Color.white);
}

fn renderLcd(cpu: *Cpu) void {
    var y: u32 = 0;
    while (y < LCD_H) : (y += 1) {
        var x_byte: u32 = 0;
        while (x_byte < BYTES_PER_ROW) : (x_byte += 1) {
            const byte = getXramByte(cpu, y, x_byte);
            var bit: u3 = 7;
            while (true) : (bit -%= 1) {
                if (byte & (@as(u8, 1) << @intCast(bit)) != 0) {
                    const px: i32 = @intCast(x_byte * 8 + (7 - @as(u32, bit)));
                    const py: i32 = @intCast(y);
                    rl.drawRectangle(px * SCALE, py * SCALE, SCALE, SCALE, FG);
                }
                if (bit == 0) break;
            }
        }
    }

    // Render bank 2 icon strip below the main LCD
    // Bank 2: 6 bytes = 48 pixels wide, rendered as a single row
    const icon_y: i32 = @intCast(LCD_H * SCALE + 4);
    var x_byte: u32 = 0;
    while (x_byte < 6) : (x_byte += 1) {
        const byte = cpu.xram_banks.bank2[x_byte];
        var bit: u3 = 7;
        while (true) : (bit -%= 1) {
            if (byte & (@as(u8, 1) << @intCast(bit)) != 0) {
                const px: i32 = @intCast(x_byte * 8 + (7 - @as(u32, bit)));
                rl.drawRectangle(px * SCALE, icon_y, SCALE, SCALE, FG);
            }
            if (bit == 0) break;
        }
    }
}

fn getXramByte(cpu: *Cpu, row: u32, byte_col: u32) u8 {
    if (row >= LCD_H) return 0;
    const xram_row = row / 2;
    const row_in_pair = row % 2;
    const offset = xram_row * 16 + row_in_pair * 6 + byte_col;
    if (offset < 128) return cpu.xram_banks.bank0[offset];
    if (offset < 256) return cpu.xram_banks.bank1[offset - 128];
    return 0;
}

fn updateButtons(cpu: *Cpu) void {
    const prev_buttons = cpu.p3_buttons;
    var buttons: u8 = 0xFF;

    const bios_launch_window = cpu.bios_phase == .bios_mode_0 or
        cpu.bios_phase == .bios_mode_1 or
        cpu.bios_phase == .bios_mode_2 or
        cpu.bios_phase == .bios_game_launch or
        (cpu.pc >= 0xE120 and cpu.pc <= 0xE1A0);

    // Real VMU BIOS launch is edge-driven: the menu wrapper confirms on a clean MODE
    // press, not on a stale held state. Repeating the same low level every frame makes
    // the P3 latch stick and prevents the ROM launch wrapper from advancing.
    const mode_key_pressed = rl.isKeyPressed(.m);
    const title_start_pressed = rl.isKeyPressed(.enter) or rl.isKeyPressed(.space);
    if (bios_launch_window) {
        buttons = 0xFF;
        if (mode_key_pressed) {
            buttons &= ~@as(u8, 0x40); // P3.6 = MODE button
        }
    } else if (azerty_mode) {
        // AZERTY: keep movement on classic arrow/d-pad keys and buttons on dedicated action keys.
        if (rl.isKeyDown(.up) or rl.isKeyDown(.w)) buttons &= ~@as(u8, 0x01); // Up
        if (rl.isKeyDown(.down) or rl.isKeyDown(.s)) buttons &= ~@as(u8, 0x02); // Down
        if (rl.isKeyDown(.left) or rl.isKeyDown(.a)) buttons &= ~@as(u8, 0x04); // Left
        if (rl.isKeyDown(.right) or rl.isKeyDown(.d)) buttons &= ~@as(u8, 0x08); // Right
        if (rl.isKeyDown(.q) or rl.isKeyDown(.z)) buttons &= ~@as(u8, 0x10); // A
        if (rl.isKeyDown(.b) or rl.isKeyDown(.x)) buttons &= ~@as(u8, 0x20); // B
    } else {
        // Standard mapping: movement on arrows/WASD, action buttons on Z/X.
        if (rl.isKeyDown(.up) or rl.isKeyDown(.w)) buttons &= ~@as(u8, 0x01); // Up
        if (rl.isKeyDown(.down) or rl.isKeyDown(.s)) buttons &= ~@as(u8, 0x02); // Down
        if (rl.isKeyDown(.left) or rl.isKeyDown(.a)) buttons &= ~@as(u8, 0x04); // Left
        if (rl.isKeyDown(.right) or rl.isKeyDown(.d)) buttons &= ~@as(u8, 0x08); // Right
        if (rl.isKeyDown(.z) or rl.isKeyDown(.k)) buttons &= ~@as(u8, 0x10); // A
        if (rl.isKeyDown(.x) or rl.isKeyDown(.l)) buttons &= ~@as(u8, 0x20); // B
    }

    // Title screen Start is a distinct press edge. Never auto-send Start when the game is
    // just booting into flash0; otherwise the title screen is skipped and the game jumps to
    // the post-title state without user input.
    if (!bios_launch_window and cpu.inst_bank.bank_id == .flash0) {
        if (title_start_pressed) {
            buttons &= ~@as(u8, 0x40); // P3.6 = Start pulse
            start_pulse_frames = 1;
        } else if (start_pulse_frames > 0) {
            buttons &= ~@as(u8, 0x40);
            start_pulse_frames -= 1;
        }
    }
    if (!bios_launch_window and cpu.inst_bank.bank_id == .rom and rl.isKeyDown(.n)) buttons &= ~@as(u8, 0x80); // P3.7 = Sleep only in BIOS

    cpu.prev_p3_buttons = prev_buttons;
    cpu.p3_buttons = buttons;
    cpu.ram_bank0[0x70] = buttons;

    // Match the BIOS harness: during the launch menu, a held MODE state must assert
    // P31INT directly so the ROM launch wrapper can continue. Keep the generic logic
    // for other buttons, but do not rely on it for BIOS selection confirmation.
    var p3int = cpu.sfr_raw[0x4E]; // P3INT
    const p30int = p3int & 0x01 != 0; // P30INT: enable interrupt
    const p32int = p3int & 0x04 != 0; // P32INT: 1=continuous, 0=edge
    const any_pressed = buttons != 0xFF;
    // MODE is a single valid edge pulse during BIOS launch; do not keep asserting P31INT
    // on every frame after a stale low-level latch remains on the port.
    const force_bios_mode_int = bios_launch_window and mode_key_pressed;

    if (p30int and ((p32int and any_pressed) or force_bios_mode_int)) {
        p3int |= 0x02; // set P31INT source flag only for a valid BIOS launch edge
    } else {
        // A stale source flag blocks the next valid press and makes the BIOS loop on the
        // same interrupt forever. Clear it when the button is released or the launch window
        // is no longer asserting a valid low-level P3 input.
        p3int &= ~@as(u8, 0x02);
    }

    cpu.sfr_raw[0x4E] = p3int;
    // VMU P3 is active-low: 0xFF means no buttons pressed. Writing 0x00 here would
    // falsely assert every button at once and make the game see a spurious all-keys
    // press/release pattern instead of a stable held directional input.
    if (buttons == 0xFF) {
        cpu.ram_bank0[0x70] = 0xFF;
    }
}

