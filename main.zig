const std = @import("std");
const Cpu = @import("lc86K").Cpu;
const decode = @import("decode");
const step = decode.step;
const rl = @import("raylib");
const dbg = @import("debug");

const LCD_W = 48;
const LCD_H = 32;
const BYTES_PER_ROW: u32 = LCD_W / 8;
const SCALE: i32 = 10;
const FG = rl.Color.init(20, 20, 20, 255);
const BG = rl.Color.init(190, 210, 180, 255);

var azerty_mode: bool = false;
var trace_mode: bool = false;

pub fn main(init: std.process.Init) !void {
    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    defer arg_iter.deinit();
    _ = arg_iter.skip();

    var path_a: ?[]const u8 = null;
    var path_b: ?[]const u8 = null;

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--azerty")) {
            azerty_mode = true;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            trace_mode = true;
        } else if (path_a == null) {
            path_a = arg;
        } else if (path_b == null) {
            path_b = arg;
        }
    }

    _ = path_a orelse {
        std.debug.print("Usage: lc86K [<bios.bin>] <game.vms> [--azerty] [--trace]\n", .{});
        return;
    };

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
    initBiosRtc(&cpu);

    dbg.init();
    dbg.log_level = if (trace_mode) .trace else .info;
    dbg.enableFileLog();
    dbg.log("=== VMU Emulator Start === BIOS: {s} ({d} bytes) Game: {s} ({d} bytes)", .{ bios_path, bios_size, game_path, game_size });

    const win_w: i32 = LCD_W * SCALE;
    const win_h: i32 = LCD_H * SCALE + 24 + SCALE + 8;
    rl.initWindow(win_w, win_h, "LC86K VMU Emulator");
    defer rl.closeWindow();
    defer flushLogFile(init);
    rl.setTargetFPS(60);

    var cycles: u64 = 0;
    var frames: u64 = 0;
    var prev_pc: u16 = 0;
    var stuck_count: u32 = 0;

    var prev_halted = false;

    while (!rl.windowShouldClose()) {
        // Flush log file periodically (every 60 frames ~ 1s) — BEFORE updateButtons
        // so that new BUTTONS entries always have room in the buffer
        if (frames % 60 == 0 and dbg.file_buf_pos > 0) {
            flushLogFile(init);
            dbg.clearLogData();
        }

        // Poll input events BEFORE reading key state, so isKeyDown reflects current frame
        rl.pollInputEvents();
        updateButtons(&cpu);

        const cycles_per_frame: u64 = 100_000;
        var i: u64 = 0;
        while (i < cycles_per_frame) : (i += 1) {
            _ = step(&cpu);
            cycles += 1;

            if (cpu.halted != prev_halted) {
                dbg.log("HALTED CHANGED: {} -> {} PC={X:0>4}", .{ prev_halted, cpu.halted, cpu.pc });
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
                        dbg.log("WAKEUP from HALT by interrupt, PC={X:0>4}", .{cpu.pc});
                        break;
                    }
                }
                cycles += ticked;
                i = cycles_per_frame;
                break;
            }

            if (cpu.pc == prev_pc) {
                stuck_count += 1;
                if (stuck_count == 300) {
                    dbg.log("STUCK at PC={X:0>4}", .{cpu.pc});
                    var j: u16 = 0;
                    while (j < 16) : (j += 1) {
                        const addr = cpu.pc +% j;
                        dbg.log("  ROM[{X:0>4}] = {X:0>2}", .{ addr, cpu.inst_bank.data[addr] });
                    }
                }
            } else {
                stuck_count = 0;
                prev_pc = cpu.pc;
            }
        }

        rl.beginDrawing();
        rl.clearBackground(BG);
        renderLcd(&cpu);

        var buf: [256]u8 = undefined;
        const status = std.fmt.bufPrintZ(&buf, "PC=0x{X:0>4} ext={X:0>2} sync={d} xram_wr={d}", .{ cpu.pc, cpu.pending_ext, cpu.sync_count, cpu.xram_write_count }) catch "??";
        rl.drawText(status, 4, win_h - 18, 14, rl.Color.white);

        rl.endDrawing();
        frames += 1;

        if (frames == 10 or frames == 30 or frames == 100 or frames == 300) {
            dbg.log("XRAM dump @ frame {d} xram_wr={d} xbnk={d}:", .{ frames, cpu.xram_write_count, cpu.sfr_raw[0x25] & 3 });
            var nonzero: u32 = 0;
            inline for (cpu.xram_banks.bank0) |b| {
                if (b != 0) nonzero += 1;
            }
            inline for (cpu.xram_banks.bank1) |b| {
                if (b != 0) nonzero += 1;
            }
            inline for (cpu.xram_banks.bank2) |b| {
                if (b != 0) nonzero += 1;
            }
            dbg.log("  bank0[0..16]: {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2}", .{
                cpu.xram_banks.bank0[0],  cpu.xram_banks.bank0[1],  cpu.xram_banks.bank0[2],  cpu.xram_banks.bank0[3],
                cpu.xram_banks.bank0[4],  cpu.xram_banks.bank0[5],  cpu.xram_banks.bank0[6],  cpu.xram_banks.bank0[7],
                cpu.xram_banks.bank0[8],  cpu.xram_banks.bank0[9],  cpu.xram_banks.bank0[10], cpu.xram_banks.bank0[11],
                cpu.xram_banks.bank0[12], cpu.xram_banks.bank0[13], cpu.xram_banks.bank0[14], cpu.xram_banks.bank0[15],
            });
            dbg.log("  bank1[0..16]: {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2}", .{
                cpu.xram_banks.bank1[0],  cpu.xram_banks.bank1[1],  cpu.xram_banks.bank1[2],  cpu.xram_banks.bank1[3],
                cpu.xram_banks.bank1[4],  cpu.xram_banks.bank1[5],  cpu.xram_banks.bank1[6],  cpu.xram_banks.bank1[7],
                cpu.xram_banks.bank1[8],  cpu.xram_banks.bank1[9],  cpu.xram_banks.bank1[10], cpu.xram_banks.bank1[11],
                cpu.xram_banks.bank1[12], cpu.xram_banks.bank1[13], cpu.xram_banks.bank1[14], cpu.xram_banks.bank1[15],
            });
            dbg.log("  bank2[0..6]:  {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2}  nonzero={d}", .{
                cpu.xram_banks.bank2[0], cpu.xram_banks.bank2[1], cpu.xram_banks.bank2[2],
                cpu.xram_banks.bank2[3], cpu.xram_banks.bank2[4], cpu.xram_banks.bank2[5],
                nonzero,
            });
        }
    }
}

/// Initialize VMU flash with a proper filesystem (same layout as DreamPotato).
/// Flash = 128KB = 256 blocks × 512 bytes.
/// Blocks 0-199: user data, 200-240: hidden, 241-253: directory, 254: FAT, 255: root.
fn initVmuFlash(cpu: *Cpu) void {
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

/// Initialize BIOS date and SFRs to match libevmu's EvmuRam_IBehavior_reset_().
/// Sets PC to 0x2E1 to skip the Dreamcast serial date query (we don't emulate the serial link).
/// Writes date to RAM and configures SFRs the BIOS expects at startup.
fn initBiosRtc(cpu: *Cpu) void {
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
    cpu.sfr_raw[0x4E] = 0xFD; // P3INT: P30INT=1 (enable), P31INT=0, P32INT=1 (continuous)
    cpu.sfr_raw[0x5C] = 0x02; // P7: P71 mask
    cpu.sfr_raw[0x5F] = 0xC0; // ISL: base timer clock = quartz oscillator
    cpu.sfr_raw[0x63] = 0xFC; // VSEL: default value
    cpu.sfr_raw[0x7F] = 0x41; // BTCR: BT_INT0_SRC=quartz, BT_INT0_IE=1
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
    var buttons: u8 = 0xFF;

    if (azerty_mode) {
        // AZERTY: ZQSD pour le d-pad, A et B sur les touches etiquetées
        if (rl.isKeyDown(.w)) buttons &= ~@as(u8, 0x01); // P3.0 = Up    (touche Z sur AZERTY)
        if (rl.isKeyDown(.s)) buttons &= ~@as(u8, 0x02); // P3.1 = Down  (touche S)
        if (rl.isKeyDown(.a)) buttons &= ~@as(u8, 0x04); // P3.2 = Left  (touche Q sur AZERTY)
        if (rl.isKeyDown(.d)) buttons &= ~@as(u8, 0x08); // P3.3 = Right (touche D)
        if (rl.isKeyDown(.q)) buttons &= ~@as(u8, 0x10); // P3.4 = A     (touche A sur AZERTY)
        if (rl.isKeyDown(.b)) buttons &= ~@as(u8, 0x20); // P3.5 = B     (touche B)
    } else {
        // QWERTY: fleches + Z/X
        if (rl.isKeyDown(.up)) buttons &= ~@as(u8, 0x01); // P3.0 = Up
        if (rl.isKeyDown(.down)) buttons &= ~@as(u8, 0x02); // P3.1 = Down
        if (rl.isKeyDown(.left)) buttons &= ~@as(u8, 0x04); // P3.2 = Left
        if (rl.isKeyDown(.right)) buttons &= ~@as(u8, 0x08); // P3.3 = Right
        if (rl.isKeyDown(.z)) buttons &= ~@as(u8, 0x10); // P3.4 = A
        if (rl.isKeyDown(.x)) buttons &= ~@as(u8, 0x20); // P3.5 = B
    }

    // Communs aux deux modes
    if (rl.isKeyDown(.enter) or rl.isKeyDown(.space) or rl.isKeyDown(.m) or rl.isKeyDown(.semicolon)) buttons &= ~@as(u8, 0x40); // P3.6 = Mode (Entrée = Start)
    if (rl.isKeyDown(.n)) buttons &= ~@as(u8, 0x80); // P3.7 = Sleep

    if (buttons != cpu.p3_buttons) {
        std.debug.print("BUTTONS: {X:0>2} -> {X:0>2} (PC={X:0>4})", .{ cpu.p3_buttons, buttons, cpu.pc });
    }
    cpu.p3_buttons = buttons;

    // libevmu EvmuGamepad_pollButtons_ / DreamPotato once-per-frame: set P31INT if
    // a button is pressed while continuous mode (P32INT) is enabled.
    var p3int = cpu.sfr_raw[0x4E]; // P3INT
    const p32int = p3int & 0x04 != 0; // P32INT: 1=continuous, 0=edge

    if (buttons != 0xFF) { // any button pressed
        if (p32int) { // continuous mode
            p3int |= 0x02; // set P31INT source flag
            cpu.sfr_raw[0x4E] = p3int;
        }
    }
    // Reset $70 (Buttons_Current) on release so next press generates a rising edge
    // for the BIOS's edge-detection (P3 ISR at 0x1F35 keeps $70/$72).
    if (buttons == 0xFF) {
        cpu.ram_bank0[0x70] = 0x00;
    }
}

fn flushLogFile(init: std.process.Init) void {
    const data = dbg.getLogData();
    if (data.len == 0) return;
    const dir = std.Io.Dir.cwd();
    const file = dir.createFile(init.io, "vmu_trace.log", .{ .truncate = false }) catch |err| {
        std.debug.print("Cannot create vmu_trace.log: {}\n", .{err});
        return;
    };
    defer file.close(init.io);
    const pos = file.length(init.io) catch 0;
    file.writePositionalAll(init.io, data, pos) catch |err| {
        std.debug.print("Cannot write vmu_trace.log: {}\n", .{err});
    };
    std.debug.print("Trace log written: {d} bytes -> vmu_trace.log\n", .{data.len});
}
