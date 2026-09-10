// Horlogerie du LC86K : Timer 0, Timer 1 et Base Timer.
//
// Fonctions libres opérant sur *Cpu pour rester testables sans hôte.
// Les constantes SFR/T0CNT/T1CNT/BTCR sont exportées par lc86K.zig.
// Références : doc/doc_timer.md, VMU.pdf (tableaux 2.19 p.229, timers).

const Cpu = @import("lc86K").Cpu;

// ref : tableau 2.19 p 229
pub fn t0Mode(self: *Cpu) u2 {
    const t0cnt = self.sfr_raw[Cpu.SFR_T0CNT];
    return @truncate((t0cnt & (Cpu.T0CNT_T0LONG | Cpu.T0CNT_T0LEXT)) >> 4);
}

pub fn tickTimer0(self: *Cpu, cycles_used: u8) void {
    const mode = t0Mode(self);
    const prescaler_period: u16 = 256 - @as(u16, self.sfr_raw[Cpu.SFR_T0PRR]);
    self.t0_prescaler_acc += cycles_used;
    while (self.t0_prescaler_acc >= prescaler_period) {
        self.t0_prescaler_acc -= prescaler_period;
        switch (mode) {
            0 => incrementT0Mode0(self),
            1 => {},
            2 => incrementT0Mode2(self),
            3 => {},
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
        self.sfr_raw[Cpu.SFR_T0CNT] |= Cpu.T0CNT_T0HOVF | Cpu.T0CNT_T0LOVF;
        self.t0l_counter = self.sfr_raw[Cpu.SFR_T0LR];
        self.t0h_counter = self.sfr_raw[Cpu.SFR_T0HR];
    }
}

fn incrementT0Mode0(self: *Cpu) void {
    const t0cnt = self.sfr_raw[Cpu.SFR_T0CNT];

    if (t0cnt & Cpu.T0CNT_T0LRUN != 0) {
        const old = self.t0l_counter;
        self.t0l_counter +%= 1;
        if (old == 0xFF) {
            self.t0l_counter = self.sfr_raw[Cpu.SFR_T0LR];
            self.sfr_raw[Cpu.SFR_T0CNT] |= Cpu.T0CNT_T0LOVF;
        }
    }

    if (t0cnt & Cpu.T0CNT_T0HRUN != 0) {
        const old = self.t0h_counter;
        self.t0h_counter +%= 1;
        if (old == 0xFF) {
            self.t0h_counter = self.sfr_raw[Cpu.SFR_T0HR];
            self.sfr_raw[Cpu.SFR_T0CNT] |= Cpu.T0CNT_T0HOVF;
        }
    }
}

// ── Timer 1 ──────────────────────────────────────────────
// Pas de prescaler : le timer tourne à la fréquence cycle clock (≈ 6 MHz)
// Mode 0 (T1LONG=0) : deux timers 8 bits indépendants (T1L, T1H)
// Mode 2 (T1LONG=1) : timer 16 bits reload (T1L overflow → T1H)
// Horloge T1L en mode 2 : Tcyc si T1HRUN=1, Tcyc/2 si T1HRUN=0

pub fn tickTimer1(self: *Cpu, cycles_used: u8) void {
    const t1cnt = self.sfr_raw[Cpu.SFR_T1CNT];
    var i: u8 = 0;
    while (i < cycles_used) : (i += 1) {
        if (t1cnt & Cpu.T1CNT_T1LONG != 0) {
            incrementT1Mode2(self);
        } else {
            incrementT1Mode0(self);
        }
    }
}

fn incrementT1Mode0(self: *Cpu) void {
    const t1cnt = self.sfr_raw[Cpu.SFR_T1CNT];

    if (t1cnt & Cpu.T1CNT_T1LRUN != 0) {
        const old = self.t1l_counter;
        self.t1l_counter +%= 1;
        if (old == 0xFF) {
            self.t1l_counter = self.sfr_raw[Cpu.SFR_T1L]; // reload depuis T1LR (même adresse)
            self.sfr_raw[Cpu.SFR_T1CNT] |= Cpu.T1CNT_T1LOVF;
        }
    }

    if (t1cnt & Cpu.T1CNT_T1HRUN != 0) {
        const old = self.t1h_counter;
        self.t1h_counter +%= 1;
        if (old == 0xFF) {
            self.t1h_counter = self.sfr_raw[Cpu.SFR_T1H]; // reload depuis T1HR (même adresse)
            self.sfr_raw[Cpu.SFR_T1CNT] |= Cpu.T1CNT_T1HOVF;
        }
    }
}

fn incrementT1Mode2(self: *Cpu) void {
    var t1cnt = self.sfr_raw[Cpu.SFR_T1CNT];

    // Mode 2 : timer 16 bits cascade
    // T1L incrémente chaque cycle si T1LRUN=1
    if (t1cnt & Cpu.T1CNT_T1LRUN != 0) {
        const old_l = self.t1l_counter;
        self.t1l_counter +%= 1;

        if (old_l == 0xFF) {
            self.t1l_counter = self.sfr_raw[Cpu.SFR_T1L]; // reload T1LR
            t1cnt |= Cpu.T1CNT_T1LOVF;

            // T1L overflow → incrémente T1H si T1HRUN=1
            if (t1cnt & Cpu.T1CNT_T1HRUN != 0) {
                const old_h = self.t1h_counter;
                self.t1h_counter +%= 1;
                if (old_h == 0xFF) {
                    self.t1h_counter = self.sfr_raw[Cpu.SFR_T1H]; // reload T1HR
                    t1cnt |= Cpu.T1CNT_T1HOVF;
                }
            }
        }
    }

    self.sfr_raw[Cpu.SFR_T1CNT] = t1cnt;
}

pub fn tickBaseTimer(self: *Cpu, cycles_used: u8) void {
    const btcr = self.sfr_raw[Cpu.SFR_BTCR];

    // BTCR6 (bit 6) = 0 → base timer arrêté, counter clear
    if (btcr & Cpu.BTCR_BT_RUN == 0) return;

    // Fixed-point Q16 : chaque cycle CPU accumule fBST_per_cycle_fp ticks base timer
    // Cache recalculé par updateBaseTimerClock() quand OCR ou Isl change
    self.base_timer_acc +%= @as(u32, self.fBST_per_cycle_fp) * cycles_used;
    while (self.base_timer_acc >= 0x10000) {
        self.base_timer_acc -= 0x10000;
        const old_counter = self.base_timer_counter;
        self.base_timer_counter = (self.base_timer_counter + 1) & 0x3FFF; // 14-bit
        const new_counter = self.base_timer_counter;

        // BT0 : configurable rate based on BTCR7
        // BTCR7=0: interrupt every 16384 ticks
        // BTCR7=1: interrupt every 64 ticks
        const int0_rate: u16 = if (btcr & Cpu.BTCR_BT0_CYCLE != 0) 0x0040 else 0x4000;
        if (old_counter / int0_rate < new_counter / int0_rate or new_counter == 0) {
            self.sfr_raw[Cpu.SFR_BTCR] |= Cpu.BTCR_BT0_FLAG;
        }

        // BT1 : seuil configurable selon BTCR5:BTCR4
        const bt1_idx: u2 = @truncate((btcr & (Cpu.BTCR_BT1_CYCLE_HI | Cpu.BTCR_BT1_CYCLE_LO)) >> 4);
        if (new_counter == Cpu.BT1_THRESHOLDS[bt1_idx]) {
            self.sfr_raw[Cpu.SFR_BTCR] |= Cpu.BTCR_BT1_FLAG;
        }
    }
}

pub fn tick(self: *Cpu, cycles_used: u8) void {
    tickTimer0(self, cycles_used);
    tickTimer1(self, cycles_used);
    tickBaseTimer(self, cycles_used);
}
