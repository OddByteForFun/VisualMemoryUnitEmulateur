const std = @import("std");
const Cpu = @import("lc86K").Cpu;
const rl = @import("raylib");

pub const Buzzer = struct {
    audio_stream: ?rl.AudioStream = null,
    audio_initialized: bool = false,
    sample_rate: u32 = 44100,
    phase: f32 = 0.0,

    pub fn init() Buzzer {
        return .{};
    }

    pub fn startAudio(self: *Buzzer) void {
        rl.initAudioDevice();
        if (rl.isAudioDeviceReady()) {
            if (rl.loadAudioStream(self.sample_rate, 16, 1)) |stream| {
                rl.playAudioStream(stream);
                self.audio_stream = stream;
                self.audio_initialized = true;
            } else |_| {}
        }
    }

    pub fn deinit(self: *Buzzer) void {
        if (self.audio_stream) |stream| {
            rl.unloadAudioStream(stream);
            self.audio_stream = null;
        }
        if (self.audio_initialized) {
            rl.closeAudioDevice();
            self.audio_initialized = false;
        }
    }

    /// Vérifie si le matériel VMU est configuré pour émettre du son via Timer 1 PWM (P1.7)
    /// Référence : libevmu EvmuBuzzer_isConfigured() (evmu_buzzer.c:125)
    pub fn isConfigured(cpu: *const Cpu) bool {
        const p1ddr = cpu.sfr_raw[Cpu.SFR_P1DDR];
        const p1fcr = cpu.sfr_raw[Cpu.SFR_P1FCR];
        const p1 = cpu.sfr_raw[Cpu.SFR_P1];
        const t1cnt = cpu.sfr_raw[Cpu.SFR_T1CNT];

        // P1.7 configuré en sortie, fonction PWM, niveau bas
        if (p1ddr & 0x80 == 0) return false;
        if (p1fcr & 0x80 == 0) return false;
        if (p1 & 0x80 != 0) return false;

        // Timer 1 configuré en mode 8-bit (mode 1 PWM) et en cours d'exécution
        if (t1cnt & Cpu.T1CNT_T1LONG != 0) return false;
        if (t1cnt & Cpu.T1CNT_T1LRUN == 0) return false;

        return true;
    }

    /// Met à jour le flux audio pour la frame courante (tampon de 735 échantillons à 44.1kHz = 1/60s)
    pub fn update(self: *Buzzer, cpu: *const Cpu) void {
        const stream = self.audio_stream orelse return;
        if (!rl.isAudioStreamProcessed(stream)) return;

        var buffer: [735]i16 = undefined; // 44100 / 60 = 735 échantillons par frame

        if (isConfigured(cpu)) {
            const t1lr = @as(u16, cpu.sfr_raw[Cpu.SFR_T1L]); // reload
            const t1lc = @as(u16, cpu.sfr_raw[Cpu.SFR_T1LC]); // comparator
            const period_ticks = 256 - t1lr;

            if (period_ticks > 0 and t1lc > t1lr) {
                const pulse_ticks = @min(t1lc - t1lr, period_ticks);
                const duty_cycle: f32 = @as(f32, @floatFromInt(pulse_ticks)) / @as(f32, @floatFromInt(period_ticks));

                // Fréquence du signal : cpu_freq / period_ticks
                // Clamp entre 50 Hz et 15000 Hz pour la sécurité acoustique
                const freq: f32 = std.math.clamp(
                    @as(f32, @floatFromInt(cpu.cpu_freq)) / @as(f32, @floatFromInt(period_ticks)),
                    50.0,
                    15000.0,
                );

                const phase_inc = freq / @as(f32, @floatFromInt(self.sample_rate));
                const volume: i16 = 6000; // volume modéré et confortable

                for (&buffer) |*sample| {
                    sample.* = if (self.phase < duty_cycle) volume else -volume;
                    self.phase += phase_inc;
                    if (self.phase >= 1.0) self.phase -= 1.0;
                }
            } else {
                @memset(&buffer, 0);
            }
        } else {
            @memset(&buffer, 0);
        }

        rl.updateAudioStream(stream, &buffer, @intCast(buffer.len));
    }
};
