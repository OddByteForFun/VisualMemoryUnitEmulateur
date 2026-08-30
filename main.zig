const std = @import("std");
const Cpu = @import("lc86K").Cpu;
const decode = @import("decode");
const step = decode.step;
const dbg = @import("debug");
const rl = @import("raylib");
const vmu = @import("vmu");

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
var current_bios_phase: ?dbg.BiosPhase = null;

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
    vmu.initVmuFlash(&cpu);

    // Load game into flash block 0 (inside the filesystem)
    const game_file = try dir.openFile(init.io, game_path, .{});
    defer game_file.close(init.io);

    const game_size = try game_file.readPositionalAll(init.io, cpu.flash[0..65536], 0);
    std.debug.print("Game: {s} ({d} bytes)\n", .{ game_path, game_size });

    // Create directory entry + FAT chain for the loaded game
    vmu.installGame(&cpu, game_size);

    cpu.reset();

    // Initialize BIOS RTC (same as DreamPotato's InitializeRTCDate)
    // The BIOS checks DateTime_DateSet (RAM 0xFF) to decide if date is ready.
    // Without this, the BIOS waits forever for the Dreamcast to send the date.
    vmu.initBiosRtc(&cpu);

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
            if (dbg.checkBiosPhase(&cpu)) |phase| {
                current_bios_phase = phase;
            }
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

        if (!bios_menu_selected and current_bios_phase == .bios_game_launch) {
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
    const phase = current_bios_phase orelse .none;

    const bios_launch_window = phase == .bios_mode_0 or
        phase == .bios_mode_1 or
        phase == .bios_mode_2 or
        phase == .bios_game_launch or
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
    const force_bios_mode_int = bios_launch_window and mode_key_pressed;

    if (p30int and ((p32int and any_pressed) or force_bios_mode_int)) {
        p3int |= 0x02; // set P31INT source flag only for a valid BIOS launch edge
    } else {
        p3int &= ~@as(u8, 0x02);
    }

    cpu.sfr_raw[0x4E] = p3int;
    if (buttons == 0xFF) {
        cpu.ram_bank0[0x70] = 0xFF;
    }
}

