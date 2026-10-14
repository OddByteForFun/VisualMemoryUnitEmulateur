const std = @import("std");
const Cpu = @import("lc86K").Cpu;
const cpu_mod = @import("lc86K");
const dbg = @import("debug");
const decode = @import("decode");
const step = decode.step;
const rl = @import("raylib");
const vmu = @import("vmu");
const Buzzer = @import("buzzer").Buzzer;

const LCD_W = 48;
const LCD_H = 32;
const BYTES_PER_ROW: u32 = LCD_W / 8;
const SCALE: i32 = 10;
const FG = rl.Color.init(20, 20, 20, 255);
const BG = rl.Color.init(190, 210, 180, 255);

var azerty_mode: bool = false;
var game_started: bool = false; // Track when game launches from BIOS
var start_pulse_frames: u32 = 0;

pub fn main(init: std.process.Init) !void {
    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    defer arg_iter.deinit();
    _ = arg_iter.skip();

    var path_a: ?[]const u8 = null;
    var path_b: ?[]const u8 = null;
    // Standalone par défaut (comme DreamPotato et le vrai VMU) : l'horloge est
    // pilotée par l'OCR (quartz ≈ 5 kHz en jeu). --docked force le mode Dreamcast 6 MHz.
    var standalone_mode: bool = true;
    var bios_menu_requested: bool = false;
    var set_time_requested: bool = false;

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--azerty")) {
            azerty_mode = true;
        } else if (std.mem.eql(u8, arg, "--bios-menu") or std.mem.eql(u8, arg, "-m")) {
            bios_menu_requested = true;
        } else if (std.mem.eql(u8, arg, "--set-time")) {
            set_time_requested = true;
            bios_menu_requested = true;
        } else if (std.mem.eql(u8, arg, "--standalone")) {
            standalone_mode = true;
        } else if (std.mem.eql(u8, arg, "--docked")) {
            standalone_mode = false;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            dbg.log_level = .trace;
            cpu_mod.storeSFRTrace = true;
            cpu_mod.p3ReadTrace = true;
        } else if (path_a == null) {
            path_a = arg;
        } else if (path_b == null) {
            path_b = arg;
        }
    }

    var bios_path: []const u8 = "roms/bios/vmu_bios_jp.bin";
    var game_path: ?[]const u8 = null;

    if (path_a) |pa| {
        if (path_b) |pb| {
            bios_path = pa;
            game_path = pb;
        } else {
            if (std.mem.endsWith(u8, pa, ".bin") or std.mem.endsWith(u8, pa, ".BIN")) {
                bios_path = pa;
                game_path = null;
            } else {
                game_path = pa;
            }
        }
    }

    const use_bios_menu: bool = bios_menu_requested or (game_path == null);

    const dir = std.Io.Dir.cwd();

    // Load BIOS into ROM (64KB padded)
    const bios_file = try dir.openFile(init.io, bios_path, .{});
    defer bios_file.close(init.io);

    const rom = init.arena.allocator().alloc(u8, 65536) catch unreachable;
    @memset(rom, 0);
    const bios_size = try bios_file.readPositionalAll(init.io, rom[0..65536], 0);
    std.debug.print("BIOS: {s} ({d} bytes)\n", .{ bios_path, bios_size });

    var cpu = Cpu.init(rom);
    cpu.dreamcast_connected = !standalone_mode;
    cpu.updateClock(); // applique le mode d'horloge

    // Initialize a proper VMU flash filesystem (same approach as DreamPotato)
    vmu.initVmuFlash(&cpu);

    if (game_path) |gp| {
        // Load game into flash block 0 (inside the filesystem)
        const game_file = try dir.openFile(init.io, gp, .{});
        defer game_file.close(init.io);

        const game_buf = try init.arena.allocator().alloc(u8, 65536);
        const game_size = try game_file.readPositionalAll(init.io, game_buf, 0);

        // Détection d'un fichier .vmi compagnon adjacent
        var maybe_vmi_data: ?[]const u8 = null;
        if (std.mem.endsWith(u8, gp, ".vms") or std.mem.endsWith(u8, gp, ".VMS")) {
            const vmi_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}.vmi", .{gp[0 .. gp.len - 4]});
            if (dir.openFile(init.io, vmi_path, .{})) |vmi_file| {
                defer vmi_file.close(init.io);
                const vmi_buf = try init.arena.allocator().alloc(u8, 256);
                const vmi_read = try vmi_file.readPositionalAll(init.io, vmi_buf, 0);
                maybe_vmi_data = vmi_buf[0..vmi_read];
                std.debug.print("VMI: {s} ({d} bytes)\n", .{ vmi_path, vmi_read });
            } else |_| {}
        }

        const vms_info = vmu.parseVms(game_buf[0..game_size], maybe_vmi_data);
        vmu.installVms(&cpu, vms_info, game_buf[0..game_size]);
        std.debug.print("Game: {s} ({d} bytes, {d} blocks, type=0x{X:0>2}, name='{s}')\n", .{
            gp,
            game_size,
            vms_info.size_blocks,
            vms_info.file_type,
            vms_info.filename,
        });
    } else {
        std.debug.print("Mode VMU autonome sans jeu : menu BIOS interactif actif\n", .{});
    }

    cpu.reset();

    // Initialize BIOS RTC (same as DreamPotato's InitializeRTCDate)
    vmu.initBiosRtc(&cpu, use_bios_menu, set_time_requested);

    if (use_bios_menu) {
        std.debug.print("BIOS menu mode enabled: P7=0x{X:0>2} (non-standalone => BIOS file menu path)\n", .{ cpu.sfr_raw[Cpu.SFR_P7] });
    }
    if (standalone_mode) {
        std.debug.print("Standalone mode: CPU={d} Hz, fBST/cycle={d}/65536\n", .{ cpu.cpu_freq, cpu.fBST_per_cycle_fp });
    } else {
        std.debug.print("Dreamcast mode: CPU=6 MHz (external clock)\n", .{});
    }

    const win_w: i32 = LCD_W * SCALE;
    const win_h: i32 = LCD_H * SCALE + 24 + SCALE + 8;
    rl.initWindow(win_w, win_h, "LC86K VMU Emulator");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var buzzer = Buzzer.init();
    buzzer.startAudio();
    defer buzzer.deinit();

    var cycles: u64 = 0;
    var frames: u64 = 0;
    var prev_pc: u16 = 0;
    var stuck_count: u32 = 0;

    var prev_halted = false;

    while (!rl.windowShouldClose()) {
        // Poll input events BEFORE reading key state, so isKeyDown reflects current frame
        rl.pollInputEvents();

        // Raccourci Soft-reset vers le menu BIOS officiel (Échap ou F1)
        if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.f1)) {
            cpu.setInstructionBank(.rom);
            cpu.reset();
            vmu.initBiosRtc(&cpu, true, false);
            game_started = false;
            start_pulse_frames = 0;
            std.debug.print("[BIOS] Reset vers le menu BIOS officiel\n", .{});
        }

        updateButtons(&cpu);

        const cycles_per_frame: u64 = cpu.cpu_freq / 60;
        var i: u64 = 0;
        while (i < cycles_per_frame) : (i += 1) {
            _ = step(&cpu);
            _ = dbg.checkBiosPhase(&cpu);
            cycles += 1;

            if (cpu.halted != prev_halted) {
                prev_halted = cpu.halted;
            }

            if (cpu.halted) {
                stuck_count = 0;
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

        if (!game_started and cpu.bios_phase == .bios_game_launch) {
            // Lancement automatique direct, ou lancement manuel depuis le menu BIOS sur appui du bouton A
            const a_pressed = rl.isKeyDown(.enter) or rl.isKeyDown(.space) or rl.isKeyDown(.k) or (if (!azerty_mode) rl.isKeyDown(.z) else rl.isKeyDown(.w));
            if (!use_bios_menu or a_pressed) {
                // Clear P3 latch before game starts
                cpu.p3_buttons = 0xFF;
                cpu.prev_p3_buttons = 0xFF;
                cpu.ram_bank0[0x70] = 0xFF;
                cpu.sfr_raw[Cpu.SFR_P3INT] = 0xFD;
                cpu.setInstructionBank(.flash0);
                cpu.pc = 0x0000;
                game_started = true;
                start_pulse_frames = 0;
            }
        }

        // Rapport périodique (1/s) : état clé pour le diagnostic runtime
        if (frames % 60 == 0) {
            var ph: []const u8 = "none";
            if (cpu.bios_phase != .none) ph = @tagName(cpu.bios_phase);
            std.debug.print("T+{d}s PC={X:0>4} OCR={X:0>2} BTCR={X:0>2} P3={X:0>2} P3I={X:0>2} IE={X:0>2} f={d}Hz phase={s} halted={} depth={d}\n", .{
                frames / 60,
                cpu.pc,
                cpu.sfr_raw[Cpu.SFR_OCR],
                cpu.sfr_raw[Cpu.SFR_BTCR],
                cpu.p3_buttons,
                cpu.sfr_raw[Cpu.SFR_P3INT],
                cpu.sfr_raw[Cpu.SFR_IE],
                cpu.cpu_freq,
                ph,
                cpu.halted,
                cpu.interrupt_depth,
            });
        }

        rl.beginDrawing();
        rl.clearBackground(BG);
        
        // LCD ghosting : ne rafraîchir que si MCR bit3 (LCD update enable) ET VCCR bit7 (LCD on)
        // VMU.txt:13502, 13878-13884 : accès XRAM interdit si quartz sélectionné, LCD off si VCCR7=0
        const mcr = cpu.sfr_raw[Cpu.SFR_MCR];
        const vccr = cpu.sfr_raw[Cpu.SFR_VCCR];
        if (mcr & 0x08 != 0 and vccr & 0x80 != 0) {
            renderLcd(&cpu);
        }
        
        // Display debug info overlay with BIOS context
        var buf: [256]u8 = undefined;
        var phase_str: []const u8 = "none";
        if (cpu.bios_phase != .none) {
            phase_str = switch (cpu.bios_phase) {
                .bios_init => "init",
                .bios_clear_ram => "clear_ram",
                .bios_post_init => "post_init",
                .bios_date_wait => "date_wait",
                .bios_lcd_setup => "lcd_setup",
                .bios_date_ok => "date_ok",
                .bios_main_loop => "main_loop",
                .bios_mode_0 => "mode_0 [Fichiers]",
                .bios_mode_1 => "mode_1 [Jeu]",
                .bios_mode_2 => "mode_2 [Horloge]",
                .bios_game_launch => "game_launch",
                .bios_no_game => "no_game",
                .game_running => "game_running",
                .none => "none",
            };
        }
        const status = std.fmt.bufPrintZ(&buf, "PC=0x{X:0>4} OCR={X:0>2} BTCR={X:0>2} P3={X:0>2} P3I={X:0>2} f={d}Hz {s}", .{ cpu.pc, cpu.sfr_raw[Cpu.SFR_OCR], cpu.sfr_raw[Cpu.SFR_BTCR], cpu.p3_buttons, cpu.sfr_raw[Cpu.SFR_P3INT], cpu.cpu_freq, phase_str }) catch "??";
        rl.drawText(status, 4, win_h - 18, 14, rl.Color.white);

        rl.endDrawing();
        buzzer.update(&cpu);
        frames += 1;

    }
}

fn renderLcd(cpu: *Cpu) void {
    var stad = cpu.sfr_raw[Cpu.SFR_STAD];
    if (stad >= 0x83) stad -%= 0x83;
    var b: u2 = @truncate(stad >> 6);
    var p: u8 = (stad & 0x3F) * 2;

    var y: u32 = 0;
    while (y < LCD_H) : (y += 1) {
        var x_byte: u32 = 0;
        while (x_byte < BYTES_PER_ROW) : (x_byte += 1) {
            const byte = switch (b) {
                0 => cpu.xram_banks.bank0[p],
                1 => cpu.xram_banks.bank1[p],
                else => 0,
            };
            p += 1;

            var bit: u3 = 7;
            while (true) : (bit -%= 1) {
                if (byte & (@as(u8, 1) << @intCast(bit)) != 0) {
                    const px: i32 = @intCast(x_byte * 8 + (7 - @as(u32, bit)));
                    const py: i32 = @intCast(y);
                    rl.drawRectangle(px * SCALE, py * SCALE, SCALE, SCALE, FG);
                }
                if (bit == 0) break;
            }

            if ((p & 0x0F) >= 12) p += 4;
            if (p >= 128) {
                b = (b + 1) % 2;
                p -= 128;
            }
        }
    }

    // Render bank 2 icon strip below the main LCD
    // Bank 2: 6 bytes = 48 pixels wide, rendered as a single row
    const icon_y: i32 = @intCast(LCD_H * SCALE + 4);
    var icon_x_byte: u32 = 0;
    while (icon_x_byte < 6) : (icon_x_byte += 1) {
        const byte = cpu.xram_banks.bank2[icon_x_byte];
        var bit: u3 = 7;
        while (true) : (bit -%= 1) {
            if (byte & (@as(u8, 1) << @intCast(bit)) != 0) {
                const px: i32 = @intCast(icon_x_byte * 8 + (7 - @as(u32, bit)));
                rl.drawRectangle(px * SCALE, icon_y, SCALE, SCALE, FG);
            }
            if (bit == 0) break;
        }
    }
}

fn updateButtons(cpu: *Cpu) void {
    const prev_buttons = cpu.p3_buttons;
    var buttons: u8 = 0xFF;

    // Navigation D-Pad (Up, Down, Left, Right)
    if (rl.isKeyDown(.up) or (if (!azerty_mode) rl.isKeyDown(.w) else rl.isKeyDown(.z))) buttons &= ~@as(u8, 0x01); // Up (P3.0)
    if (rl.isKeyDown(.down) or rl.isKeyDown(.s)) buttons &= ~@as(u8, 0x02); // Down (P3.1)
    if (rl.isKeyDown(.left) or (if (!azerty_mode) rl.isKeyDown(.a) else rl.isKeyDown(.q))) buttons &= ~@as(u8, 0x04); // Left (P3.2)
    if (rl.isKeyDown(.right) or rl.isKeyDown(.d)) buttons &= ~@as(u8, 0x08); // Right (P3.3)

    // Bouton A (Action / Sélection / Confirmation)
    if (rl.isKeyDown(.enter) or rl.isKeyDown(.space) or rl.isKeyDown(.k) or (if (!azerty_mode) rl.isKeyDown(.z) else rl.isKeyDown(.w))) {
        buttons &= ~@as(u8, 0x10); // A (P3.4)
    }

    // Bouton B (Annulation / Retour)
    if (rl.isKeyDown(.x) or rl.isKeyDown(.b) or rl.isKeyDown(.l) or rl.isKeyDown(.backspace)) {
        buttons &= ~@as(u8, 0x20); // B (P3.5)
    }

    // Bouton MODE (P3.6) : bascule entre Horloge / Fichiers / Jeu dans le BIOS
    const mode_key_pressed = rl.isKeyPressed(.m) or rl.isKeyPressed(.tab);
    if (rl.isKeyDown(.m) or rl.isKeyDown(.tab)) {
        buttons &= ~@as(u8, 0x40); // MODE (P3.6)
    }

    // Bouton SLEEP (P3.7) : mise en veille
    if (rl.isKeyDown(.n)) {
        buttons &= ~@as(u8, 0x80); // SLEEP (P3.7)
    }

    // Start pulse en jeu (flash0) sur écran titre
    const title_start_pressed = rl.isKeyPressed(.enter) or rl.isKeyPressed(.space);
    if (cpu.inst_bank.bank_id == .flash0) {
        if (title_start_pressed) {
            buttons &= ~@as(u8, 0x40); // P3.6 = Start pulse
            start_pulse_frames = 1;
        } else if (start_pulse_frames > 0) {
            buttons &= ~@as(u8, 0x40);
            start_pulse_frames -= 1;
        }
    }

    cpu.p3_buttons = buttons;
    cpu.ram_bank0[0x70] = buttons;

    // Log des changements de boutons pour debug
    if (buttons != prev_buttons) {
        std.debug.print("P3 buttons: 0x{X:0>2} -> 0x{X:0>2} (prev=0x{X:0>2}) p3int=0x{X:0>2}\n", .{
            prev_buttons, buttons, prev_buttons, cpu.sfr_raw[Cpu.SFR_P3INT],
        });
    }

    var p3int = cpu.sfr_raw[Cpu.SFR_P3INT]; // P3INT
    const p30int = p3int & Cpu.P3INT_P30INT != 0; // P30INT: enable interrupt
    const p32int = p3int & Cpu.P3INT_P32INT != 0; // P32INT: 1=continuous, 0=edge
    const any_pressed = buttons != 0xFF;
    const any_just_pressed = (prev_buttons & buttons) != prev_buttons; // fronts montants (0→1 = appui)

    if (p30int) {
        if (p32int) {
            // Mode continu : P31INT posé tant qu'un bouton est appuyé
            if (any_pressed) {
                p3int |= Cpu.P3INT_P31INT;
            } else {
                p3int &= ~Cpu.P3INT_P31INT;
            }
        } else {
            // Mode edge : P31INT posé sur front montant (appui), pas d'effacement auto.
            if (any_just_pressed or mode_key_pressed) {
                p3int |= Cpu.P3INT_P31INT;
            }
        }
    } else {
        p3int &= ~Cpu.P3INT_P31INT;
    }

    cpu.prev_p3_buttons = prev_buttons;
    cpu.sfr_raw[Cpu.SFR_P3INT] = p3int;
    if (buttons == 0xFF) {
        cpu.ram_bank0[0x70] = 0xFF;
    }
}

