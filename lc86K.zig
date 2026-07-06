const std = @import("std");

pub const Psw = packed struct(u8) {
    p: bool = false, // bit 0 — Parity (odd parity of ACC, read-only)
    rambk0: bool = false, // bit 1 — RAM bank select (0=bank0, 1=bank1)
    ov: bool = false, // bit 2 — Overflow (signed overflow)
    irbk0: bool = false, // bit 3 — Indirect register bank 0
    irbk1: bool = false, // bit 4 — Indirect register bank 1
    _: bool = false, // bit 5 — Reserved
    ac: bool = false, // bit 6 — Auxiliary Carry (carry from bit 3)
    cy: bool = false, // bit 7 — Carry (unsigned overflow)
};

pub const Cpu = struct {
    // Banque d'instructions (64KB, 3 banks : ROM / Flash0 / Flash1)
    inst_bank: struct {
        data: []u8,
        bank_id: enum { rom, flash0, flash1 },
    },

    // RAM space (512 octets, accédé par load/store)
    ram_bank0: [256]u8, // bank 0 : système + stack
    ram_bank1: [256]u8, // bank 1 : application
    sfr_raw: [0x80]u8, // backing store pour 0x100-0x17F
    xram_banks: struct {
        bank0: [96]u8, // XBNK=0 : LCD rows 0-15 (6B/row)
        bank1: [96]u8, // XBNK=1 : LCD rows 16-31 (6B/row)
        bank2: [6]u8, // XBNK=2 : icônes
    },
    work_ram: [512]u8, // buffer DMA Maple (via VTRBF/VRMAD)

    // Flash storage (128KB)
    flash: [131072]u8, // 2 banks × 64KB, filesystem FAT

    // Registres CPU (convenience, synced avec sfr_raw)
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    sp: u8 = 0,
    pc: u16 = 0,
    trl: u8 = 0,
    trh: u8 = 0,
    psw: Psw = .{},
    halted: bool = false,

    pub fn init(rom: []u8) Cpu {
        return Cpu{
            .inst_bank = .{
                .data = rom,
                .bank_id = .rom,
            },
            .ram_bank0 = .{0} ** 256,
            .ram_bank1 = .{0} ** 256,
            .sfr_raw = .{0} ** 0x80,
            .xram_banks = .{
                .bank0 = .{0} ** 96,
                .bank1 = .{0} ** 96,
                .bank2 = .{0} ** 6,
            },
            .work_ram = .{0} ** 512,
            .flash = .{0} ** 131072,
        };
    }

    pub fn reset(self: *Cpu) void {
        self.pc = 0;
        self.a = 0;
        self.b = 0;
        self.c = 0;
        self.sp = 0;
        self.psw = .{};
        self.halted = false;
        @memset(&self.ram_bank0, 0);
        @memset(&self.ram_bank1, 0);
        @memset(&self.sfr_raw, 0);
        @memset(&self.xram_banks.bank0, 0);
        @memset(&self.xram_banks.bank1, 0);
        @memset(&self.xram_banks.bank2, 0);
        @memset(&self.work_ram, 0);
        @memset(&self.flash, 0);
    }

    pub fn currentRamBank(self: *Cpu) *[256]u8 {
        return if (self.psw.rambk0) &self.ram_bank1 else &self.ram_bank0;
    }

    pub fn load8(self: *Cpu, addr: u9) u8 {
        return switch (addr) {
            0...0xFF => self.currentRamBank()[addr],
            0x100...0x17F => self.loadSFR(@as(u7, @truncate(addr - 0x100))),
            0x180...0x1FF => self.loadXram(@as(u7, @truncate(addr - 0x180))),
        };
    }

    pub fn store8(self: *Cpu, addr: u9, val: u8) void {
        switch (addr) {
            0...0xFF => {
                self.currentRamBank()[addr] = val;
            },
            0x100...0x17F => {
                self.storeSFR(@as(u7, @truncate(addr - 0x100)), val);
            },
            0x180...0x1FF => {
                self.storeXram(@as(u7, @truncate(addr - 0x180)), val);
            },
        }
    }

    // il s'agit de définir les offsets utilisés par load8 qui ajoute 0x100 à ces valeurs.

    const SFR_ACC: u7 = 0x00;
    const SFR_PSW: u7 = 0x01;
    const SFR_B: u7 = 0x02;
    const SFR_C: u7 = 0x03;
    const SFR_TRL: u7 = 0x04;
    const SFR_TRH: u7 = 0x05;
    const SFR_SP: u7 = 0x06;
    const SFR_IE: u7 = 0x08;
    const SFR_IP: u7 = 0x09;

    pub fn loadSFR(self: *Cpu, offset: u7) u8 {
        return switch (offset) {
            SFR_ACC => self.a,
            SFR_B => self.b,
            SFR_C => self.c,
            SFR_TRL => self.trl,
            SFR_TRH => self.trh,
            SFR_PSW => @as(u8, @bitCast(self.psw)),
            SFR_SP => self.sp,
            else => self.sfr_raw[offset],
        };
    }

    pub fn storeSFR(self: *Cpu, offset: u7, val: u8) void {
        self.sfr_raw[offset] = val;
        switch (offset) {
            SFR_ACC => self.a = val,
            SFR_B => self.b = val,
            SFR_C => self.c = val,
            SFR_TRL => self.trl = val,
            SFR_TRH => self.trh = val,
            SFR_PSW => self.psw = @bitCast(val),
            SFR_SP => self.sp = val,
            else => {},
        }
    }

    pub fn loadXram(self: *Cpu, offset: u7) u8 {
        _ = self;
        _ = offset;
        // TODO: dispatch XBNK
        return 0xFF;
    }

    pub fn storeXram(self: *Cpu, offset: u7, val: u8) void {
        _ = self;
        _ = offset;
        _ = val;
        // TODO: dispatch XBNK
    }

    pub fn fetch8(self: *Cpu) u8 {
        const val = self.inst_bank.data[self.pc];
        self.pc += 1;
        return val;
    }

    pub fn fetch16(self: *Cpu) u16 {
        const lo: u8 = self.fetch8();
        const hi: u8 = self.fetch8();
        return (@as(u16, hi) << 8) | @as(u16, lo);
    }

    pub fn read16At(self: *Cpu, addr: u9) u16 {
        const lo: u8 = self.load8(addr);
        const hi: u8 = self.load8(addr + 1);
        return (@as(u16, hi) << 8) | @as(u16, lo);
    }

    pub fn write16At(self: *Cpu, addr: u9, val: u16) void {
        self.store8(addr, @truncate(val));
        self.store8(addr + 1, @truncate(val >> 8));
    }
};

pub fn main() void {
    const rom = std.heap.page_allocator.alloc(u8, 65536) catch unreachable;
    defer std.heap.page_allocator.free(rom);
    var cpu = Cpu.init(rom);
    cpu.reset();
}
