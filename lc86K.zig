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

    // Registres CPU
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    sp: u8 = 0,
    pc: u16 = 0,
    trl: u8 = 0,
    trh: u8 = 0,
    psw: Psw = .{},
    halted: bool = false,

    // Timer 0
    t0l_counter: u8 = 0,
    t0h_counter: u8 = 0,
    t0_prescaler_acc: u16 = 0,

    // base timer
    base_timer_acc: u32 = 0,
    base_timer_counter: u16 = 0,

    // interruptions
    interrupt_depth: u8 = 0, // verifier sur une IRQ est possible (0, ok, 1 attente RETI)
    interrupt_blocked: u8 = 0,

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
        self.t0l_counter = 0;
        self.t0h_counter = 0;
        self.t0_prescaler_acc = 0;
        self.base_timer_acc = 0;
        self.base_timer_counter = 0;
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

    /// ref : tableau 2.19 p 229
    // timer 0 mode 0

    fn t0IsMode0(self: *Cpu) bool {
        const t0cnt = self.sfr_raw[SFR_T0CNT];
        return (t0cnt & T0CNT_T0LONG == 0) and (t0cnt & T0CNT_T0LEXT == 0);
    }

    // Timer 0 mode 1

    fn t0IsMode1(self: *Cpu) bool {
        const t0cnt = self.sfr_raw[SFR_T0CNT];
        return (t0cnt & T0CNT_T0LONG == 0) and (t0cnt & T0CNT_T0LEXT != 0);
    }

    // Timer 0 mode 2

    fn t0IsMode2(self: *Cpu) bool {
        const t0cnt = self.sfr_raw[SFR_T0CNT];
        return (t0cnt & T0CNT_T0LONG != 0) and (t0cnt & T0CNT_T0LEXT == 0);
    }

    // timer 0 mode 3

    fn t0IsMode3(self: *Cpu) bool {
        const t0cnt = self.sfr_raw[SFR_T0CNT];
        return (t0cnt & T0CNT_T0LONG != 0) and (t0cnt & T0CNT_T0LEXT != 0);
    }

    pub fn tickTimer0(self: *Cpu, cycles_used: u8) void {
        const t0cnt = self.sfr_raw[SFR_T0CNT];
        const mode = (t0cnt >> 4) & 0x03; //nibble haut avec bit 6 et 7
        // commun à tous les modes

        const prescaler_period: u16 = 256 - @as(u16, self.sfr_raw[SFR_T0PRR]);
        self.t0_prescaler_acc += cycles_used;
        while (self.t0_prescaler_acc >= prescaler_period) {
            self.t0_prescaler_acc -= prescaler_period;
            switch (mode) {
                0 => self.incrementT0Mode0(),
                1 => {},
                2 => self.incrementT0Mode2(),
                3 => {},
                else => {},
            }
        }
    }

    fn incrementT0Mode2(self: *Cpu) void {
        const old_l = self.t0l_counter;
        self.t0l_counter +%= 1;

        if (old_l == 0xFF) {
            self.t0h_counter +%= 1;
        }

        if (old_l == 0xFF and self.t0h_counter == 0x00) {
            self.sfr_raw[SFR_T0CNT] |= T0CNT_T0HOVF | T0CNT_T0LOVF;
            self.t0l_counter = self.sfr_raw[SFR_T0LR];
            self.t0h_counter = self.sfr_raw[SFR_T0HR];
        }
    }

    fn incrementT0Mode0(self: *Cpu) void {
        const t0cnt = self.sfr_raw[SFR_T0CNT];

        if (t0cnt & T0CNT_T0LRUN != 0) {
            const old = self.t0l_counter;
            self.t0l_counter +%= 1;
            if (old == 0xFF) {
                self.t0l_counter = self.sfr_raw[SFR_T0LR];
                self.sfr_raw[SFR_T0CNT] |= T0CNT_T0LOVF;
            }
        }

        if (t0cnt & T0CNT_T0HRUN != 0) {
            const old = self.t0h_counter;
            self.t0h_counter +%= 1;
            if (old == 0xFF) {
                self.t0h_counter = self.sfr_raw[SFR_T0HR];
                self.sfr_raw[SFR_T0CNT] |= T0CNT_T0HOVF;
            }
        }
    }

    pub fn tickBaseTimer(self: *Cpu, cycles_used: u8) void {
        const btcr = self.sfr_raw[SFR_BTCR];

        // BTCR6 (bit 6) = 0 → base timer arrêté, counter clear
        if (btcr & BTCR_BT_RUN == 0) return;

        self.base_timer_acc += cycles_used;
        while (self.base_timer_acc >= CYCLES_PER_FBST_TICK) {
            self.base_timer_acc -= CYCLES_PER_FBST_TICK;
            self.base_timer_counter = (self.base_timer_counter + 1) & 0x3FFF; // 14-bit

            // BT0 : overflow du compteur 14-bit (16384 ticks = ~0.5s)
            if (self.base_timer_counter == 0) {
                self.sfr_raw[SFR_BTCR] |= BTCR_BT0_FLAG;
            }

            // BT1 : seuil configurable selon BTCR5:BTCR4
            const bt1_idx: u2 = @truncate((btcr & (BTCR_BT1_CYCLE_HI | BTCR_BT1_CYCLE_LO)) >> 4);
            if (self.base_timer_counter == BT1_THRESHOLDS[bt1_idx]) {
                self.sfr_raw[SFR_BTCR] |= BTCR_BT1_FLAG;
            }
        }
    }

    pub fn tickTimers(self: *Cpu, cycles_used: u8) void {
        self.tickTimer0(cycles_used);
        self.tickBaseTimer(cycles_used);
    }

    // gestion des interuptions.
    // verification de certains flags posés par les timers
    // complété par de nombreux flags
    // Premières implémentations (INT2/TOL, INT3, T0H) basées sur les timers
    // p314

    pub const Interruptions = enum(u8) {
        int2, // t0l
        int3, // base timer
        t0h, // t0h
    };

    pub fn servicePendingInterrupt(self: *Cpu) void {
        var val: ?Interruptions = null;

        if (self.interrupt_depth != 0) return;

        if (self.interrupt_blocked > 0) {
            self.interrupt_blocked -%= 1;
            return;
        }

        const ie = self.sfr_raw[SFR_IE];
        const t0cnt = self.sfr_raw[SFR_T0CNT];
        const btcr = self.sfr_raw[SFR_BTCR];

        if (ie & 0x80 == 0) return; // pas d'interruptions autorisées (EA)

        if (t0cnt & T0CNT_T0LOVF != 0 and t0cnt & T0CNT_T0LIE != 0 and ie & IP_int2 != 0) {
            val = .int2;
        } else if (ie & IP_int3 != 0 and
            ((btcr & BTCR_BT0_FLAG != 0 and btcr & BTCR_BT0_IE != 0) or
            (btcr & BTCR_BT1_FLAG != 0 and btcr & BTCR_BT1_IE != 0)))
        {
            val = .int3;
        } else if (t0cnt & T0CNT_T0HOVF != 0 and t0cnt & T0CNT_T0HIE != 0 and ie & IP_t0h != 0) {
            val = .t0h;
        }

        const vecteur: u16 = if (val) |irq| switch (irq) {
            .int2 => 0x0013,
            .int3 => 0x001B,
            .t0h => 0x0023,
        } else return;

        const return_addr = self.pc;
        self.sp +%= 1;
        self.ram_bank0[self.sp] = @truncate(return_addr & 0xFF);
        self.sp +%= 1;
        self.ram_bank0[self.sp] = @truncate(return_addr >> 8);
        self.pc = vecteur;
        self.interrupt_depth = 1;
        self.halted = false;

        if (val) |irq| switch (irq) {
            .int2 => self.sfr_raw[SFR_T0CNT] &= ~T0CNT_T0LOVF,
            .int3 => self.sfr_raw[SFR_BTCR] &= ~(BTCR_BT0_FLAG | BTCR_BT1_FLAG),
            .t0h => self.sfr_raw[SFR_T0CNT] &= ~T0CNT_T0HOVF,
        };
    }

    // il s'agit de définir les offsets utilisés par load8 qui ajoute 0x100 à ces valeurs.

    const SFR_ACC: u7 = 0x00;
    const SFR_PSW: u7 = 0x01;
    const SFR_B: u7 = 0x02;
    const SFR_C: u7 = 0x03;
    const SFR_TRL: u7 = 0x04;
    const SFR_TRH: u7 = 0x05;
    const SFR_SP: u7 = 0x06;
    const SFR_IE: u7 = 0x08; // autorisation d'interruption
    const SFR_IP: u7 = 0x09;

    // Timer 0 mode 2
    const SFR_T0PRR: u7 = 0x11; //  valeur du prescaler Timer 0
    const SFR_T0L: u7 = 0x12; // Lecture du compteur courant
    const SFR_T0LR: u7 = 0x13; // Lecture écriture du reload
    const SFR_T0H: u7 = 0x14; // compteur high courant
    const SFR_T0HR: u7 = 0x15; //  reload high
    const SFR_T0CNT: u7 = 0x4E; //  contrôle, flags et enables
    const SFR_PCON: u7 = 0x07; // Power control (bit 0 = HALT mode)
    const SFR_I23CR: u7 = 0x5E; // sélection front externe INT2/INT3
    const SFR_ISL: u7 = 0x5F; //  sélection entrée externe et horloge

    // Octet qui compose T0CNT
    const T0CNT_T0HRUN: u8 = 0x80;
    const T0CNT_T0LRUN: u8 = 0x40;
    const T0CNT_T0LONG: u8 = 0x20;
    const T0CNT_T0LEXT: u8 = 0x10;
    const T0CNT_T0HOVF: u8 = 0x08; // utilisé pour les interruptions mode 0
    const T0CNT_T0HIE: u8 = 0x04; // T0H interrupt request enabled
    const T0CNT_T0LOVF: u8 = 0x02; // utilisé pour les interruptions mode 0
    const T0CNT_T0LIE: u8 = 0x01; // T0L interrupt request enabled

    // Base Timer
    const SFR_BTCR: u7 = 0x7F; // gestion notamment des interruptions du base timer
    const BTCR_BT0_IE: u8 = 0x01; // bit 0: BT0 request enable
    const BTCR_BT0_FLAG: u8 = 0x02; // bit 1: BT0 source flag
    const BTCR_BT1_IE: u8 = 0x04; // bit 2: BT1 request enable
    const BTCR_BT1_FLAG: u8 = 0x08; // bit 3: BT1 source flag
    const BTCR_BT1_CYCLE_LO: u8 = 0x10; // bit 4: BT1 cycle control low
    const BTCR_BT1_CYCLE_HI: u8 = 0x20; // bit 5: BT1 cycle control high
    const BTCR_BT_RUN: u8 = 0x40; // bit 6: base timer start/stop
    const BTCR_BT0_CYCLE: u8 = 0x80; // bit 7: BT0 cycle control (0: 16384/fBST, 1: 64/fBST fast-forward)

    // fBST = 32768 Hz quartz. CPU ≈ 6 MHz. 1 tick fBST ≈ 183 cycles CPU.
    const CPU_FREQ: u32 = 6_000_000;
    const FST_FREQ: u32 = 32_768;
    const CYCLES_PER_FBST_TICK: u32 = CPU_FREQ / FST_FREQ; // 183
    const BT1_THRESHOLDS: [4]u16 = .{ 32, 128, 512, 2048 }; // cycles fBST selon BTCR5:BTCR4

    // Priorisation des interruptions (bits du registre IE)
    const IP_int2: u8 = 0x04; // IE bit 2 = ET2 (INT2_T0L)
    const IP_int3: u8 = 0x08; // IE bit 3 = ET3 (INT3_BT)
    const IP_t0h: u8 = 0x10; // IE bit 4 = ET0H (T0H)
    const IP_T1: u8 = 0x20; // IE bit 5 = ET1 (Timer 1)
    const IP_SIO0: u8 = 0x40; // IE bit 6
    const IP_SIO1: u8 = 0x80; // IE bit 7

    pub fn loadSFR(self: *Cpu, offset: u7) u8 {
        return switch (offset) {
            SFR_ACC => self.a,
            SFR_B => self.b,
            SFR_C => self.c,
            SFR_TRL => self.trl,
            SFR_TRH => self.trh,
            SFR_PSW => @as(u8, @bitCast(self.psw)),
            SFR_SP => self.sp,
            SFR_T0L => self.t0l_counter,
            SFR_T0H => self.t0h_counter,
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
            SFR_IE, SFR_IP => {
                self.interrupt_blocked = 1;
            },
            SFR_T0LR => {
                // si le timer n'est pas en cours d'éxécution, on recharge le compteur low avec la valeur écrite dans T0LR.
                //Sinon, on ne fait rien.
                if (self.sfr_raw[SFR_T0CNT] & T0CNT_T0LRUN == 0) {
                    self.t0l_counter = val;
                }
            },
            SFR_T0HR => {
                // si le timer n'est pas en cours d'éxécution, on recharge le compteur high avec la valeur écrite dans T0HR.
                //Sinon, on ne fait rien.
                if (self.sfr_raw[SFR_T0CNT] & T0CNT_T0HRUN == 0) {
                    self.t0h_counter = val;
                }
            },
            SFR_PCON => {
                if (val & 0x01 != 0) {
                    self.halted = true;
                }
            },
            SFR_T0CNT => {
                if (val & T0CNT_T0LRUN == 0) {
                    self.t0l_counter = self.sfr_raw[SFR_T0LR];
                }
                if (val & T0CNT_T0HRUN == 0) {
                    self.t0h_counter = self.sfr_raw[SFR_T0HR];
                }
            },
            SFR_BTCR => {
                if (val & BTCR_BT_RUN == 0) {
                    self.base_timer_counter = 0;
                    self.base_timer_acc = 0;
                }
            },

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
