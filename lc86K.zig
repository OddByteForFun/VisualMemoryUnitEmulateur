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
    rom_data: []u8, // sauvegarde du slice ROM pour pouvoir revenir depuis Flash
    pending_ext: u8 = 0, // valeur en attente du registre Ext (bank switch différé sur JMPF)

    // RAM space (512 octets, accédé par load/store)
    ram_bank0: [256]u8, // bank 0 : système + stack
    ram_bank1: [256]u8, // bank 1 : application
    sfr_raw: [0x80]u8, // backing store pour 0x100-0x17F
    xram_banks: struct {
        bank0: [128]u8, // XBNK=0 : LCD rows 0-15 (16B/row, dead cols 0xC-0xF)
        bank1: [128]u8, // XBNK=1 : LCD rows 16-31
        bank2: [6]u8, // XBNK=2 : icônes
    },
    work_ram: [512]u8, // buffer DMA Maple (via VTRBF/VRMAD)
    vrmad: u16 = 0, // adresse courante dans work_ram (combinée VRMAD2:VRMAD1)

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

    // Timer 1
    t1l_counter: u8 = 0,
    t1h_counter: u8 = 0,

    // base timer
    base_timer_acc: u32 = 0,
    base_timer_counter: u16 = 0,

    // interruptions
    interrupt_depth: u8 = 0, // verifier sur une IRQ est possible (0, ok, 1 attente RETI)
    interrupt_blocked: u8 = 0,
    process_this_instr: bool = true, // libevmu processThisInstr: skip PIC dispatch 1 instr after RETI

    // Ports I/O
    p3_buttons: u8 = 0xFF, // état physique des boutons (active-low, 1=relâché)
    prev_p3_buttons: u8 = 0xFF, // état précédent pour détection de front (edge mode)

    // Compteurs d'événements matériels (instrumentation ; incrémentés au
    // cœur des chemins store8/VTRBF/sync — les sortir de Cpu imposerait une
    // dépendance lc86K→debug, interdite par l'architecture).
    xram_write_count: u32 = 0,
    vtrbf_write_count: u32 = 0,
    sync_count: u32 = 0, // how many times syncInstructionBank was called
    maple_irq_pending: bool = false, // IRQ 9 (Maple RFB) pending flag

    pub fn init(rom: []u8) Cpu {
        var cpu = Cpu{
            .inst_bank = .{
                .data = rom,
                .bank_id = .rom,
            },
            .rom_data = rom,
            .ram_bank0 = @splat(0),
            .ram_bank1 = @splat(0),
            .sfr_raw = @splat(0),
            .xram_banks = .{
                .bank0 = @splat(0),
                .bank1 = @splat(0),
                .bank2 = @splat(0),
            },
            .work_ram = @splat(0),
            .flash = @splat(0),
        };
        cpu.sp = 0x7F; // Stack pointer (hardware reset default)
        applySfrResetDefaults(&cpu);
        cpu.pending_ext = 0x80; // Ext3=1, Ext0=0 → ROM mode
        return cpu;
    }

    pub fn reset(self: *Cpu) void {
        self.pc = 0;
        self.a = 0;
        self.b = 0;
        self.c = 0;
        self.sp = 0x7F;
        self.psw = .{};
        self.halted = false;
        @memset(&self.ram_bank0, 0);
        @memset(&self.ram_bank1, 0);
        @memset(&self.sfr_raw, 0);
        @memset(&self.xram_banks.bank0, 0);
        @memset(&self.xram_banks.bank1, 0);
        @memset(&self.xram_banks.bank2, 0);
        @memset(&self.work_ram, 0);
        self.t0l_counter = 0;
        self.t0h_counter = 0;
        self.t0_prescaler_acc = 0;
        self.t1l_counter = 0;
        self.t1h_counter = 0;
        self.base_timer_acc = 0;
        self.base_timer_counter = 0;
        applySfrResetDefaults(self);
        self.inst_bank = .{ .data = self.rom_data, .bank_id = .rom };
        self.pending_ext = 0x80; // Ext3=1, Ext0=0 → ROM mode (comme DreamPotato)
    }

    /// Défauts SFR après reset matériel (table 2.6, p.158 + référence DreamPotato).
    /// Source unique partagée par init() et reset().
    fn applySfrResetDefaults(self: *Cpu) void {
        self.sfr_raw[SFR_IE] = 0x80; // 108H: Master interrupt enable (EA=1)
        self.sfr_raw[SFR_SP] = 0x7F; // 106H: Stack pointer
        self.sfr_raw[SFR_P1FCR] = 0xBF; // 146H: Port 1 function control
        self.sfr_raw[SFR_P3INT] = 0x00; // 14EH: Port 3 interrupt
        self.sfr_raw[SFR_ISL] = 0xC0; // 15FH: Input signal select
        self.sfr_raw[SFR_BTCR] = 0x41; // 17FH: Base timer control (BT0_CYCLE + BT0_IE)
        self.sfr_raw[SFR_VCCR] = 0x80; // 127H: LCD display control (VCCR7=1)
        self.sfr_raw[SFR_VSEL] = 0xFC; // 163H: VTRBF control (INCE=1 + reset defaults)
        self.sfr_raw[SFR_EXT] = 0x80; // 10DH: External memory control (Ext3=1, Ext0=0 → ROM)
    }

    /// Synchronise l'inst_bank avec la valeur courante de pending_ext.
    /// Appelé uniquement après JMPF (bank switch différé).
    pub fn syncInstructionBank(self: *Cpu) void {
        self.sync_count += 1;
        const ext = self.pending_ext;
        // Interprétation selon DreamPotato : Ext3 (bit 3) et Ext0 (bit 0)
        // ROM         → Ext3=1, Ext0=0
        // FlashBank0  → Ext3=1, Ext0=1
        // FlashBank1  → Ext3=0, Ext0=0
        if (ext & 0x08 != 0) {
            // Ext3 = 1
            if (ext & 0x01 != 0) {
                // Ext0 = 1 → FlashBank0
                self.inst_bank.data = self.flash[0..65536];
                self.inst_bank.bank_id = .flash0;
            } else {
                // Ext0 = 0 → ROM
                self.inst_bank.data = self.rom_data;
                self.inst_bank.bank_id = .rom;
            }
        } else {
            // Ext3 = 0 → FlashBank1
            self.inst_bank.data = self.flash[65536..131072];
            self.inst_bank.bank_id = .flash1;
        }
    }

    /// Fixe directement la bank d'instructions (pour usage UI/tests).
    pub fn setInstructionBank(self: *Cpu, bank: enum { rom, flash0, flash1 }) void {
        switch (bank) {
            .rom => {
                self.pending_ext = 0x80; // Ext3=1, Ext0=0
                self.inst_bank.data = self.rom_data;
                self.inst_bank.bank_id = .rom;
            },
            .flash0 => {
                self.pending_ext = 0x89; // Ext3=1, Ext0=1
                self.inst_bank.data = self.flash[0..65536];
                self.inst_bank.bank_id = .flash0;
            },
            .flash1 => {
                self.pending_ext = 0x00; // Ext3=0, Ext0=0
                self.inst_bank.data = self.flash[65536..131072];
                self.inst_bank.bank_id = .flash1;
            },
        }
    }

    pub fn currentRamBank(self: *Cpu) *[256]u8 {
        return if (self.psw.rambk0) &self.ram_bank1 else &self.ram_bank0;
    }

    pub fn load8(self: *Cpu, addr: u9) u8 {
        const result = switch (addr) {
            0...0xFF => self.currentRamBank()[addr],
            0x100...0x17F => self.loadSFR(@as(u7, @truncate(addr - 0x100))),
            0x180...0x1FF => self.loadXram(@as(u7, @truncate(addr - 0x180))),
        };
        return result;
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
                self.xram_write_count += 1;
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

    // ── Timer 1 ──────────────────────────────────────────────
    // Pas de prescaler : le timer tourne à la fréquence cycle clock (≈ 6 MHz)
    // Mode 0 (T1LONG=0) : deux timers 8 bits indépendants (T1L, T1H)
    // Mode 2 (T1LONG=1) : timer 16 bits reload (T1L overflow → T1H)
    // Horloge T1L en mode 2 : Tcyc si T1HRUN=1, Tcyc/2 si T1HRUN=0

    pub fn tickTimer1(self: *Cpu, cycles_used: u8) void {
        const t1cnt = self.sfr_raw[SFR_T1CNT];
        var i: u8 = 0;
        while (i < cycles_used) : (i += 1) {
            if (t1cnt & T1CNT_T1LONG != 0) {
                self.incrementT1Mode2();
            } else {
                self.incrementT1Mode0();
            }
        }
    }

    fn incrementT1Mode0(self: *Cpu) void {
        const t1cnt = self.sfr_raw[SFR_T1CNT];

        if (t1cnt & T1CNT_T1LRUN != 0) {
            const old = self.t1l_counter;
            self.t1l_counter +%= 1;
            if (old == 0xFF) {
                self.t1l_counter = self.sfr_raw[SFR_T1L]; // reload depuis T1LR (même adresse)
                self.sfr_raw[SFR_T1CNT] |= T1CNT_T1LOVF;
            }
        }

        if (t1cnt & T1CNT_T1HRUN != 0) {
            const old = self.t1h_counter;
            self.t1h_counter +%= 1;
            if (old == 0xFF) {
                self.t1h_counter = self.sfr_raw[SFR_T1H]; // reload depuis T1HR (même adresse)
                self.sfr_raw[SFR_T1CNT] |= T1CNT_T1HOVF;
            }
        }
    }

    fn incrementT1Mode2(self: *Cpu) void {
        var t1cnt = self.sfr_raw[SFR_T1CNT];

        // Mode 2 : timer 16 bits cascade
        // T1L incrémente chaque cycle si T1LRUN=1
        if (t1cnt & T1CNT_T1LRUN != 0) {
            const old_l = self.t1l_counter;
            self.t1l_counter +%= 1;

            if (old_l == 0xFF) {
                self.t1l_counter = self.sfr_raw[SFR_T1L]; // reload T1LR
                t1cnt |= T1CNT_T1LOVF;

                // T1L overflow → incrémente T1H si T1HRUN=1
                if (t1cnt & T1CNT_T1HRUN != 0) {
                    const old_h = self.t1h_counter;
                    self.t1h_counter +%= 1;
                    if (old_h == 0xFF) {
                        self.t1h_counter = self.sfr_raw[SFR_T1H]; // reload T1HR
                        t1cnt |= T1CNT_T1HOVF;
                    }
                }
            }
        }

        self.sfr_raw[SFR_T1CNT] = t1cnt;
    }

    pub fn tickBaseTimer(self: *Cpu, cycles_used: u8) void {
        const btcr = self.sfr_raw[SFR_BTCR];

        // BTCR6 (bit 6) = 0 → base timer arrêté, counter clear
        if (btcr & BTCR_BT_RUN == 0) return;

        self.base_timer_acc += cycles_used;
        while (self.base_timer_acc >= CYCLES_PER_FBST_TICK) {
            self.base_timer_acc -= CYCLES_PER_FBST_TICK;
            const old_counter = self.base_timer_counter;
            self.base_timer_counter = (self.base_timer_counter + 1) & 0x3FFF; // 14-bit
            const new_counter = self.base_timer_counter;

            // BT0 : configurable rate based on BTCR7
            // BTCR7=0: interrupt every 16384 ticks
            // BTCR7=1: interrupt every 64 ticks
            const int0_rate: u16 = if (btcr & BTCR_BT0_CYCLE != 0) 0x0040 else 0x4000;
            if (old_counter / int0_rate < new_counter / int0_rate or new_counter == 0) {
                self.sfr_raw[SFR_BTCR] |= BTCR_BT0_FLAG;
            }

            // BT1 : seuil configurable selon BTCR5:BTCR4
            const bt1_idx: u2 = @truncate((btcr & (BTCR_BT1_CYCLE_HI | BTCR_BT1_CYCLE_LO)) >> 4);
            if (new_counter == BT1_THRESHOLDS[bt1_idx]) {
                self.sfr_raw[SFR_BTCR] |= BTCR_BT1_FLAG;
            }
        }
    }

    pub fn tickTimers(self: *Cpu, cycles_used: u8) void {
        self.tickTimer0(cycles_used);
        self.tickTimer1(cycles_used);
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
        t1, // timer 1 (T1H ou T1L overflow)
        p3, // Port 3 level interrupt (buttons)
        maple, // Maple IRQ 9 (IRQ RFB)
    };

    pub fn requestLevelDrivenInterrupts(self: *Cpu) void {
        // P31INT is now set by updateButtons() in main.zig (once per frame,
        // matching libevmu's EvmuGamepad_pollButtons_). Empty here to avoid
        // per-instruction IRQ storms.
        _ = self;
    }

    pub fn servicePendingInterrupt(self: *Cpu) void {
        var val: ?Interruptions = null;

        if (self.interrupt_depth != 0) return;

        // libevmu processThisInstr: skip dispatch for 1 instruction after RETI
        if (!self.process_this_instr) {
            self.process_this_instr = true;
            return;
        }

        if (self.interrupt_blocked > 0) {
            self.interrupt_blocked -%= 1;
            return;
        }

        const ie = self.sfr_raw[SFR_IE];
        const t0cnt = self.sfr_raw[SFR_T0CNT];
        const btcr = self.sfr_raw[SFR_BTCR];

        if (ie & 0x80 == 0) return; // pas d'interruptions autorisées (EA)

        // Sur le vrai LC86K, IE ne contient que EA (bit7) + IE1/IE0 (priorité INT0/INT1).
        // Les enables individuels sont dans les registres des périphériques (T0CNT, BTCR, T1CNT).
        if (t0cnt & T0CNT_T0LOVF != 0 and t0cnt & T0CNT_T0LIE != 0) {
            val = .int2;
        } else if ((btcr & BTCR_BT0_FLAG != 0 and btcr & BTCR_BT0_IE != 0) or
            (btcr & BTCR_BT1_FLAG != 0 and btcr & BTCR_BT1_IE != 0))
        {
            val = .int3;
        } else if (t0cnt & T0CNT_T0HOVF != 0 and t0cnt & T0CNT_T0HIE != 0) {
            val = .t0h;
        } else {
            const t1cnt = self.sfr_raw[SFR_T1CNT];
            if (t1cnt & T1CNT_T1HOVF != 0 and t1cnt & T1CNT_T1HIE != 0) {
                val = .t1;
            } else if (t1cnt & T1CNT_T1LOVF != 0 and t1cnt & T1CNT_T1LIE != 0) {
                val = .t1;
            }
        }

        // Port 3 interrupt (priority 10, vector 0x004BH)
        // Continuous mode (P32INT=1): Source flag set while any P3 pin is LOW (button pressed)
        // Edge mode (P32INT=0): Source flag set on falling edge (handled in P3 setter)
        // Interrupt fires when Enable (P30INT) AND Source (P31INT) are both set
        if (val == null) {
            const p3int = self.sfr_raw[SFR_P3INT];
            if (p3int & P3INT_P30INT != 0 and p3int & P3INT_P31INT != 0) {
                val = .p3;
            }
        }

        // Maple IRQ 9 (IRQ RFB, vector 0x0043)
        // Triggered when Maple transfer completes (TXDONE or IRQREQ in MPLSTA)
        if (val == null and self.maple_irq_pending) {
            val = .maple;
        }

        const vecteur: u16 = if (val) |irq| switch (irq) {
            .int2 => 0x0013,
            .int3 => 0x001B,
            .t0h => 0x0023,
            .t1 => 0x002B,
            .maple => 0x0043,
            .p3 => 0x004B,
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
            .t1 => {
                self.sfr_raw[SFR_T1CNT] &= ~(T1CNT_T1HOVF | T1CNT_T1LOVF);
            },
            .p3 => {}, // P31INT source flag stays set until cleared by ISR
            .maple => self.maple_irq_pending = false,
        };
    }

    // il s'agit de définir les offsets utilisés par load8 qui ajoute 0x100 à ces valeurs.

    pub const SFR_ACC: u7 = 0x00;
    pub const SFR_PSW: u7 = 0x01;
    pub const SFR_B: u7 = 0x02;
    pub const SFR_C: u7 = 0x03;
    pub const SFR_TRL: u7 = 0x04;
    pub const SFR_TRH: u7 = 0x05;
    pub const SFR_SP: u7 = 0x06;
    pub const SFR_IE: u7 = 0x08; // autorisation d'interruption
    pub const SFR_IP: u7 = 0x09;
    pub const SFR_OCR: u7 = 0x0E; // oscillateur : quartz/RC et division d'horloge
    pub const SFR_MCR: u7 = 0x20; // contrôle Maple/LCD (bit3 = mise à jour LCD)

    // Timer 0 mode 2
    pub const SFR_T0PRR: u7 = 0x11; //  valeur du prescaler Timer 0
    pub const SFR_T0L: u7 = 0x12; // Lecture du compteur courant
    pub const SFR_T0LR: u7 = 0x13; // Lecture écriture du reload
    pub const SFR_T0H: u7 = 0x14; // compteur high courant
    pub const SFR_T0HR: u7 = 0x15; //  reload high
    pub const SFR_T0CNT: u7 = 0x10; //  contrôle, flags et enables (adresse hardware 0x110)
    pub const SFR_PCON: u7 = 0x07; // Power control (bit 0 = HALT mode)
    pub const SFR_VSEL: u7 = 0x63; // Control register (INCE=bit4, ASEL=bit0)
    pub const SFR_VRMAD1: u7 = 0x64; // Work RAM address low byte
    pub const SFR_VRMAD2: u7 = 0x65; // Work RAM address high (VRMAD8=bit0 = bank)
    pub const SFR_VTRBF: u7 = 0x66; // Work RAM data access (read/write via VRMAD)
    pub const SFR_VLREG: u7 = 0x67; // Maple word count
    pub const SFR_MPLSW: u7 = 0x60; // Maple status word
    pub const SFR_MPLSTA: u7 = 0x61; // Maple start/status (bit0=TXDONE, bit1=IRQREQ, bit6=UNK)
    pub const SFR_MPLRST: u7 = 0x62; // Maple reset
    pub const SFR_XBNK: u7 = 0x25; // Sélection banque XRAM (LCD)
    pub const SFR_P1: u7 = 0x44; // Port 1 (série + PWM audio)
    pub const SFR_P1DDR: u7 = 0x45; // Port 1 data direction
    pub const SFR_P1FCR: u7 = 0x46; // Port 1 function control
    pub const SFR_P3: u7 = 0x4C; // Port 3 (boutons, input-only)
    pub const SFR_P3DDR: u7 = 0x4D; // Port 3 data direction (ne pas modifier)
    pub const SFR_P3INT: u7 = 0x4E; // Port 3 interrupt control
    pub const SFR_P7: u7 = 0x5C; // Port 7 (détection tension, read-only)
    pub const SFR_I23CR: u7 = 0x5E; // sélection front externe INT2/INT3
    pub const SFR_ISL: u7 = 0x5F; //  sélection entrée externe et horloge
    pub const SFR_VCCR: u7 = 0x27; // LCD contrast/power control

    // Octet qui compose T0CNT
    pub const T0CNT_T0HRUN: u8 = 0x80;
    pub const T0CNT_T0LRUN: u8 = 0x40;
    pub const T0CNT_T0LONG: u8 = 0x20;
    pub const T0CNT_T0LEXT: u8 = 0x10;
    pub const T0CNT_T0HOVF: u8 = 0x08; // utilisé pour les interruptions mode 0
    pub const T0CNT_T0HIE: u8 = 0x04; // T0H interrupt request enabled
    pub const T0CNT_T0LOVF: u8 = 0x02; // utilisé pour les interruptions mode 0
    pub const T0CNT_T0LIE: u8 = 0x01; // T0L interrupt request enabled

    // Timer 1 — SFR offsets (0x118-0x11D → offset - 0x100)
    pub const SFR_T1CNT: u7 = 0x18; // control, flags, enables
    pub const SFR_T1LC: u7 = 0x1A; // low comparator data
    pub const SFR_T1L: u7 = 0x1B; // low counter (read) / T1LR reload (write)
    pub const SFR_T1HC: u7 = 0x1C; // high comparator data
    pub const SFR_T1H: u7 = 0x1D; // high counter (read) / T1HR reload (write)

    // P3INT bits
    pub const P3INT_P30INT: u8 = 0x01; // bit 0: interrupt request enable
    pub const P3INT_P31INT: u8 = 0x02; // bit 1: interrupt source flag (set when LOW detected)
    pub const P3INT_P32INT: u8 = 0x04; // bit 2: interrupt generation enable

    // T1CNT bits
    pub const T1CNT_T1HRUN: u8 = 0x80; // T1H count control
    pub const T1CNT_T1LRUN: u8 = 0x40; // T1L count control
    pub const T1CNT_T1LONG: u8 = 0x20; // 0=mode 0/1 (8-bit), 1=mode 2/3 (16-bit)
    pub const T1CNT_T1HOVF: u8 = 0x08; // T1H overflow flag
    pub const T1CNT_T1HIE: u8 = 0x04; // T1H interrupt request enable
    pub const T1CNT_T1LOVF: u8 = 0x02; // T1L overflow flag
    pub const T1CNT_T1LIE: u8 = 0x01; // T1L interrupt request enable

    // Base Timer
    pub const SFR_BTCR: u7 = 0x7F; // gestion notamment des interruptions du base timer
    pub const BTCR_BT0_IE: u8 = 0x01; // bit 0: BT0 request enable
    pub const BTCR_BT0_FLAG: u8 = 0x02; // bit 1: BT0 source flag
    pub const BTCR_BT1_IE: u8 = 0x04; // bit 2: BT1 request enable
    pub const BTCR_BT1_FLAG: u8 = 0x08; // bit 3: BT1 source flag
    pub const BTCR_BT1_CYCLE_LO: u8 = 0x10; // bit 4: BT1 cycle control low
    pub const BTCR_BT1_CYCLE_HI: u8 = 0x20; // bit 5: BT1 cycle control high
    pub const BTCR_BT_RUN: u8 = 0x40; // bit 6: base timer start/stop
    pub const BTCR_BT0_CYCLE: u8 = 0x80; // bit 7: BT0 cycle control (0: 16384/fBST, 1: 64/fBST fast-forward)

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

    pub const SFR_EXT: u7 = 0x0D;
    pub const SFR_FPR: u7 = 0x54; // Flash Protection Register (bit0=FlashAddressBank, bit1=FlashWriteUnlock)

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
            SFR_T1L => self.t1l_counter,
            SFR_T1H => self.t1h_counter,
            SFR_P3 => {
                return self.p3_buttons;
            },
            SFR_VTRBF => {
                const addr = self.vrmad & 0x1FF;
                const data = if (addr < 512) self.work_ram[addr] else 0xFF;
                if (self.sfr_raw[SFR_VSEL] & 0x10 != 0) {
                    self.vrmad +%= 1;
                }
                return data;
            },
            SFR_MPLSTA => {
                return self.sfr_raw[SFR_MPLSTA];
            },
            else => self.sfr_raw[offset],
        };
    }

    pub fn storeSFR(self: *Cpu, offset: u7, val: u8) void {
        if (offset == SFR_MPLSTA) return; // read-only register
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
            SFR_P3INT => {
                // P3INT layout (VMU.pdf):
                //   bit 0: P30INT — interrupt enable (R/W)
                //   bit 1: P31INT — source flag, cleared by writing 0
                //   bit 2: P32INT — mode (0=edge, 1=continuous) (R/W)
                //   bit 3: P33INT — current P3 pin state (R only)
                // CLR1 P3INT,#1 clears bit 1; software writes clear the source flag.
                const old = self.sfr_raw[SFR_P3INT];
                // Preserve read-only bit 3 (current P3 pin state)
                const writable = val & 0x07;
                self.sfr_raw[SFR_P3INT] = (old & 0x08) | writable;
            },
            SFR_T0CNT => {
                if (val & T0CNT_T0LRUN == 0) {
                    self.t0l_counter = self.sfr_raw[SFR_T0LR];
                }
                if (val & T0CNT_T0HRUN == 0) {
                    self.t0h_counter = self.sfr_raw[SFR_T0HR];
                }
            },
            0x20 => {}, // MCR (LCD Mode Control)
            0x27 => {}, // VCCR (LCD contrast/power)
            0x22 => {}, // STAD (Display start address)
            SFR_VSEL => { // VSEL: bits read/write (reset defaults: 0xFC)
                self.sfr_raw[SFR_VSEL] = val;
            },
            SFR_VRMAD1 => {
                self.vrmad = (self.vrmad & 0x100) | @as(u16, val);
            },
            SFR_VRMAD2 => {
                self.vrmad = (self.vrmad & 0xFF) | (@as(u16, val & 0x01) << 8);
            },
            SFR_MPLRST => {
                // Maple reset: write $80 then $00 to reset Maple bus
                self.sfr_raw[SFR_MPLRST] = val;
            },
            SFR_MPLSTA => {
            },
            SFR_VTRBF => {
                const addr = self.vrmad & 0x1FF;
                self.vtrbf_write_count +%= 1;
                if (addr < 512) {
                    self.work_ram[addr] = val;
                }
                if (self.sfr_raw[SFR_VSEL] & 0x10 != 0) {
                    self.vrmad +%= 1;
                }
            },
            SFR_BTCR => {
                if (val & BTCR_BT_RUN == 0) {
                    self.base_timer_counter = 0;
                    self.base_timer_acc = 0;
                }
            },
            SFR_T1L => {
                // T1L et T1LR partagent la même adresse : écriture = reload
                self.sfr_raw[SFR_T1L] = val;
                if (self.sfr_raw[SFR_T1CNT] & T1CNT_T1LRUN == 0) {
                    self.t1l_counter = val;
                }
            },
            SFR_T1H => {
                // T1H et T1HR partagent la même adresse : écriture = reload
                self.sfr_raw[SFR_T1H] = val;
                if (self.sfr_raw[SFR_T1CNT] & T1CNT_T1HRUN == 0) {
                    self.t1h_counter = val;
                }
            },
            SFR_T1CNT => {
                // Si T1LRUN passe à 0 → reload T1L depuis T1LR
                if (val & T1CNT_T1LRUN == 0) {
                    self.t1l_counter = self.sfr_raw[SFR_T1L];
                }
                // Si T1HRUN passe à 0 → reload T1H depuis T1HR
                if (val & T1CNT_T1HRUN == 0) {
                    self.t1h_counter = self.sfr_raw[SFR_T1H];
                }
            },
            SFR_EXT => {
                self.pending_ext = val;
            },

            else => {},
        }
    }

    pub fn loadXram(self: *Cpu, offset: u7) u8 {
        const xbnk = self.sfr_raw[SFR_XBNK] & 0x03;
        return switch (xbnk) {
            0 => if ((offset & 0x0F) < 0x0C) self.xram_banks.bank0[offset] else 0xFF,
            1 => if ((offset & 0x0F) < 0x0C) self.xram_banks.bank1[offset] else 0xFF,
            2 => if (offset < 6) self.xram_banks.bank2[offset] else 0xFF,
            else => 0xFF,
        };
    }

    pub fn storeXram(self: *Cpu, offset: u7, val: u8) void {
        const xbnk = self.sfr_raw[SFR_XBNK] & 0x03;
        switch (xbnk) {
            0 => {
                if ((offset & 0x0F) < 0x0C) self.xram_banks.bank0[offset] = val;
            },
            1 => {
                if ((offset & 0x0F) < 0x0C) self.xram_banks.bank1[offset] = val;
            },
            2 => {
                if (offset < 6) self.xram_banks.bank2[offset] = val;
            },
            else => {},
        }
    }

    pub fn fetch8(self: *Cpu) u8 {
        const val = self.inst_bank.data[self.pc];
        self.pc +%= 1;
        return val;
    }

    /// LDF: read flash at 17-bit address = TRL | (TRH << 8) | (FPR.FlashAddressBank ? 0x10000 : 0)
    pub fn readFlash(self: *Cpu) u8 {
        const a17: u17 = @as(u17, self.trl) | (@as(u17, self.trh) << 8) | (if (self.sfr_raw[SFR_FPR] & 0x01 != 0) @as(u17, 0x10000) else 0);
        if (a17 < 131072) return self.flash[a17];
        return 0xFF;
    }

    /// STF: write flash at 17-bit address (only if FlashWriteUnlock sequence matched)
    pub fn writeFlash(self: *Cpu, val: u8) void {
        const a17: u17 = @as(u17, self.trl) | (@as(u17, self.trh) << 8) | (if (self.sfr_raw[SFR_FPR] & 0x01 != 0) @as(u17, 0x10000) else 0);
        if (a17 < 131072) {
            self.flash[a17] = val;
        }
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
