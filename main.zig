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

    const rom_path = arg_iter.next() orelse {
        std.debug.print("Usage: lc86K <rom.bin> [--azerty] [--trace]\n", .{});
        return;
    };

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--azerty")) azerty_mode = true;
        if (std.mem.eql(u8, arg, "--trace")) trace_mode = true;
    }

    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(init.io, rom_path, .{});
    defer file.close(init.io);

    const rom = init.arena.allocator().alloc(u8, 65536) catch unreachable;
    @memset(rom, 0);
    const n = try file.readPositionalAll(init.io, rom[0..65536], 0);
    std.debug.print("ROM: {d} bytes\n", .{n});

    var cpu = Cpu.init(rom);
    cpu.reset();

    dbg.init();
    dbg.log_level = if (trace_mode) .trace else .info;
    dbg.enableFileLog();
    dbg.log("=== VMU Emulator Start === ROM: {s} ({d} bytes)", .{ rom_path, n });

    const win_w: i32 = LCD_W * SCALE;
    const win_h: i32 = LCD_H * SCALE + 24;
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

        if (frames % 60 == 0) {
            dbg.log("HALTED STATUS: halted={} PC={X:0>4} cyc={d} p3_reads={d} p3={X:0>2} P3INT={X:0>2} IE={X:0>2} depth={d} blk={d}", .{
                cpu.halted, cpu.pc, cycles, cpu.p3_read_count, cpu.p3_buttons,
                cpu.sfr_raw[0x4E], cpu.sfr_raw[0x08], cpu.interrupt_depth, cpu.interrupt_blocked,
            });
            cpu.p3_read_count = 0;
            if (dbg.loop_detected_pc) |lp| {
                dbg.log("LOOP DETECTED at PC={X:0>4} count={d}", .{ lp, dbg.loop_count });
            }
        }
        // Poll input events BEFORE reading key state, so isKeyDown reflects current frame
        rl.pollInputEvents();
        updateButtons(&cpu);

        // Periodic diagnostic to stderr (visible in terminal)
        if (frames % 120 == 0) {
            std.debug.print("[frame {d}] enter={} m={} semicolon={} focused={}\n", .{
                frames,
                rl.isKeyDown(.enter),
                rl.isKeyDown(.m),
                rl.isKeyDown(.semicolon),
                rl.isWindowFocused(),
            });
        }
        // Detect any key press and print its code
        while (true) {
            const key = rl.getKeyPressed();
            if (@intFromEnum(key) == 0) break;
            std.debug.print("KEY PRESSED: code={d} ({s})\n", .{ @intFromEnum(key), @tagName(key) });
        }

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

        var buf: [128]u8 = undefined;
        const status = std.fmt.bufPrintZ(&buf, "PC=0x{X:0>4}  cyc={d}  halted={}  frames={d}  xram_wr={d}", .{ cpu.pc, cycles, cpu.halted, frames, cpu.xram_write_count }) catch "??";
        rl.drawText(status, 4, win_h - 18, 14, rl.Color.white);

        rl.endDrawing();
        frames += 1;
    }
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
        dbg.log("BUTTONS: {X:0>2} -> {X:0>2} (PC={X:0>4})", .{ cpu.p3_buttons, buttons, cpu.pc });
    }
    cpu.p3_buttons = buttons;
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
