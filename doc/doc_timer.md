# Timers & Interruptions LC86K

Référence : VMU Hardware Manual, table 2.19 (p229), table 2.22 (BTCR), section HALT mode (p164).

---

## Vue d'ensemble

L'émulateur gère 3 sources d'interruption timer :
- **INT2 (0x0013)** : Timer 0 Low overflow
- **INT3 (0x001B)** : Base Timer (BT0 et BT1)
- **T0H (0x0023)** : Timer 0 High overflow

La boucle principale est dans `decode.zig:step()` :
1. Si `cpu.halted == true` → skip instruction, tickTimers + servicePendingInterrupt, retour 1 cycle
2. Sinon → fetch + decode + execute instruction
3. En fin de step : `tickTimers(cycles_used)` puis `servicePendingInterrupt()`

---

## Timer 0 — Modes

Le mode est déterminé par les bits T0LONG (bit 5) et T0LEXT (bit 4) du registre T0CNT.

| Mode | T0LONG | T0LEXT | Fonction | Statut |
|------|--------|--------|----------|--------|
| 0 | 0 | 0 | Deux timers 8 bits indépendants (T0L, T0H) | ✅ Implémenté |
| 1 | 0 | 1 | Timer 8 bits + compteur externe (P72/P73) | ❌ Pas implémenté |
| 2 | 1 | 0 | Timer 16 bits reload (T0H:T0L combiné) | ✅ Implémenté |
| 3 | 1 | 1 | Conteur externe 16 bits (P72/P73) | ❌ Pas implémenté |

**SFRs :** T0PRR (0x11), T0L (0x12), T0LR (0x13), T0H (0x14), T0HR (0x15), T0CNT (0x4E)

### Timer 0 Mode 2 — Timer 16 bits reload

**Fonctionnement :**
- T0H:T0L forme un compteur 16 bits qui incrémente à chaque tick prescaler
- Prescaler : `TPR = 256 - T0PRR`, accumulation dans `t0_prescaler_acc`
- L'incrémentation se fait dans `incrementT0Mode2()` :
  - T0L est incrémenté en premier
  - Si T0L overflow (old == 0xFF), T0H est incrémenté
  - Si T0L **et** T0H overflow (old_l == 0xFF && t0h == 0x00) → overflow 16-bit complet :
    - Flags `T0HOVF | T0LOVF` posés dans T0CNT
    - Reload : T0L ← T0LR, T0H ← T0HR
- **`loadSFR`** : T0L retourne `t0l_counter` (compteur courant, pas le reload)
- **`storeSFR`** :
  - Écriture T0LR → met à jour `sfr_raw[T0LR]` + reset `t0l_counter` (seulement si T0LRUN=0)
  - Écriture T0HR → met à jour `sfr_raw[T0HR]` + reset `t0h_counter` (seulement si T0HRUN=0)
  - Écriture T0CNT → reload les compteurs si le mode passe à STOP

### Timer 0 Mode 0 — Deux timers 8 bits indépendants

**Fonctionnement :**
- T0L et T0H sont deux compteurs 8 bits indépendants
- Chacun a son propre bit RUN (T0LRUN bit 6, T0HRUN bit 7) et son propre flag (T0LOVF, T0HOVF)
- L'incrémentation se fait dans `incrementT0Mode0()` :
  - Si T0LRUN=1 : incrémente T0L, si overflow → reload depuis T0LR + pose T0LOVF
  - Si T0HRUN=1 : incrémente T0H, si overflow → reload depuis T0HR + pose T0HOVF
- Chaque timer peut être démarré/arrêté indépendamment via ses bits RUN

---

## Base Timer

**SFR :** BTCR (0x7F)

### Registre BTCR — bits complets

| Bit | Nom | Fonction |
|-----|-----|----------|
| 7 | BTCR7 | Cycle BT0 : 0 = 16384/fBST (~0.5s), 1 = 64/fBST (~2ms, fast-forward) |
| 6 | BTCR6 | Start/stop : 1 = start, 0 = stop + clear counter 14-bit |
| 5 | BTCR5 | Cycle BT1 (bit haut) — voir table ci-dessous |
| 4 | BTCR4 | Cycle BT1 (bit bas) — voir table ci-dessous |
| 3 | BTCR3 | BT1 source flag (posé quand le compteur atteint le seuil) |
| 2 | BTCR2 | BT1 request enable (autorise l'envoi de l'interruption INT3) |
| 1 | BTCR1 | BT0 source flag (posé quand le compteur 14-bit overflow) |
| 0 | BTCR0 | BT0 request enable (autorise l'envoi de l'interruption INT3) |

**Note :** BTCR7, BTCR6, BTCR0 ne doivent pas être manipulés par l'application (bits système).

### Périodes BT1

BT0 et BT1 partagent le même vecteur INT3 (0x001B). Le code ISR doit véraler quel flag est posé.

| BTCR7 | BTCR5 | BTCR4 | Période BT1 | En ticks fBST |
|-------|-------|-------|-------------|---------------|
| x | 0 | 0 | 32/fBST | ~0.976 ms |
| x | 0 | 1 | 128/fBST | ~3.906 ms |
| 0 | 1 | 0 | 512/fBST | ~15.625 ms |
| 0 | 1 | 1 | 2048/fBST | ~62.5 ms |

fBST = 32 768 Hz (quartz). En cycles CPU (~6 MHz) : 1 tick fBST ≈ 183 cycles CPU.

### Implémentation

**`tickBaseTimer(cycles_used)`** (lc86K.zig:212) :
1. Si BTCR6=0 → retour immédiat (timer arrêté)
2. Accumule les cycles CPU dans `base_timer_acc`
3. Pour chaque tick fBST (183 cycles CPU) :
   - Incrémente `base_timer_counter` (14 bits, wrapping à 0x3FFF)
   - **BT0** : si counter == 0 (overflow 14-bit) → pose BTCR_BT0_FLAG
   - **BT1** : si counter == seuil BTCR5:BTCR4 (32/128/512/2048) → pose BTCR_BT1_FLAG

**`storeSFR` pour BTCR** (lc86K.zig:415) :
- Si BTCR6 passe à 0 → clear `base_timer_counter` et `base_timer_acc`

---

## Interruptions

### Fonction `servicePendingInterrupt()` (lc86K.zig:253)

Appelée à chaque fin de `step()`, après `tickTimers()`.

**Ordre de priorité** (if/else if) :
1. **INT2** (INT2_T0L) — priorité la plus haute
2. **INT3** (Base Timer BT0 ou BT1)
3. **T0H** — priorité la plus basse

**Conditions de déclenchement** (toutes requises) :
- `IE.bit 7` (EA) = 1 — master interrupt enable
- `interrupt_depth == 0` — pas déjà en train de servir une IRQ
- `interrupt_blocked == 0` — pas en période de blocage après écriture IE/IP
- Flag source = 1 (T0LOVF, BTCR_BT0_FLAG ou BTCR_BT1_FLAG, T0HOVF)
- Enable local = 1 (T0LIE, BTCR_BT0_IE ou BTCR_BT1_IE, T0HIE)
- Enable IE = 1 (IP_int2, IP_int3, IP_t0h)

**Quand une IRQ est servie** :
1. Push du PC courant sur la stack (hi byte en premier, lo en second) — même format que `call`
2. `self.pc` ← adresse du vecteur
3. `self.interrupt_depth` ← 1 (bloque le nesting)
4. `self.halted` ← false (réveil du CPU si en HALT)
5. **Clear du flag source** (voir ci-dessous)

### Clear des flags après service

C'est critique : sans clear, l'IRQ se reboucle indéfiniment après RETI car le flag reste posé.

| IRQ servie | Flag(s) clear |
|------------|---------------|
| INT2 (T0L) | `T0CNT &= ~T0CNT_T0LOVF` (bit 1) |
| INT3 (Base Timer) | `BTCR &= ~(BTCR_BT0_FLAG \| BTCR_BT1_FLAG)` (bits 1+3) |
| T0H | `T0CNT &= ~T0CNT_T0HOVF` (bit 3) |

Pour INT3, on clear les deux flags (BT0 + BT1) car ils partagent le même vecteur. Le code ISR lui-même identifie la source en lisant les flags.

### Instruction RETI (decode.zig:539)

```
PC.high ← (SP); SP--
PC.low  ← (SP); SP--
interrupt_depth ← 0
```

### Blocage après écriture IE/IP

Quand l'application écrit dans IE ou IP (`storeSFR`), `interrupt_blocked` est mis à 1. Pendant le cycle suivant, `servicePendingInterrupt()` ne fait rien et décrémente `interrupt_blocked`. Cela évite qu'une interuption ne soit servie avec les anciennes priorités juste après un changement de configuration.

### Vecteurs d'interruption

| IRQ | Vecteur | Source |
|-----|---------|--------|
| INT2 | 0x0013 | Timer 0 Low overflow |
| INT3 | 0x001B | Base Timer (BT0 ou BT1) |
| T0H | 0x0023 | Timer 0 High overflow |
| T1 | 0x002B | Timer 1 (pas encore implémenté) |

---

## HALT Mode

**SFR :** PCON (0x07), bit 0

**Activation :** `set1 PCON,0` → écriture de 1 dans le bit 0 de PCON → `cpu.halted = true`

**Comportement en HALT :**
- Le CPU ne fetch ni n'exécute d'instructions
- Les timers continuent de tourner (tickTimers appelé avec 1 cycle)
- Le CPU peut être réveillé par une interuption

**Réveil :**
- Quand `servicePendingInterrupt()` sert une IRQ → `cpu.halted = false` + jump au vecteur ISR
- Le CPU reprend l'exécution à l'adresse du vecteur d'interruption

**Implémentation dans `step()` (decode.zig:258) :**
```zig
if (cpu.halted) {
    cpu.tickTimers(1);
    cpu.servicePendingInterrupt();
    return 1;
}
```

**Implémentation dans `storeSFR()` (lc86K.zig:402) :**
```zig
SFR_PCON => {
    if (val & 0x01 != 0) {
        self.halted = true;
    }
},
```

---

## Timer 0 — Prescaler

Commun à tous les modes. Le prescaler divise l'horloge CPU avant d'incrémenter les compteurs.

- Registre T0PRR (0x11) contient la valeur de reload du prescaler
- Période du prescaler : `TPR = 256 - T0PRR`
- Accumulation dans `t0_prescaler_acc` (u16)
- À chaque `tickTimer0(cycles_used)` :
  - `t0_prescaler_acc += cycles_used`
  - Pendant que `t0_prescaler_acc >= prescaler_period` :
    - `t0_prescaler_acc -= prescaler_period`
    - Incrémente le compteur du mode actif

---

## Fonctions Cpu — Récapitulatif

| Fonction | Fichier:ligne | Rôle |
|----------|--------------|------|
| `t0IsMode0()` | lc86K.zig:130 | Vérifie T0LONG=0, T0LEXT=0 |
| `t0IsMode1()` | lc86K.zig:137 | Vérifie T0LONG=0, T0LEXT=1 |
| `t0IsMode2()` | lc86K.zig:144 | Vérifie T0LONG=1, T0LEXT=0 |
| `t0IsMode3()` | lc86K.zig:151 | Vérifie T0LONG=1, T0LEXT=1 |
| `tickTimer0(cycles)` | lc86K.zig:156 | Prescaler + dispatch mode 0/2 |
| `incrementT0Mode2()` | lc86K.zig:175 | Incrémente T0H:T0L 16-bit, overflow + reload |
| `incrementT0Mode0()` | lc86K.zig:190 | Incrémente T0L et T0H 8-bit indépendamment |
| `tickBaseTimer(cycles)` | lc86K.zig:212 | Compteur 14-bit fBST, BT0 + BT1 |
| `tickTimers(cycles)` | lc86K.zig:236 | Appelle tickTimer0 + tickBaseTimer |
| `servicePendingInterrupt()` | lc86K.zig:253 | Détection + service IRQ (push PC, jump vector, clear flag, wake HALT) |
| `loadSFR(offset)` | lc86K.zig:360 | Lecture SFR (retourne compteurs courants pour T0L/T0H) |
| `storeSFR(offset, val)` | lc86K.zig:373 | Écriture SFR + effets de bord (reload, HALT, arrêt timer) |

---

## Constantes SFR

| Constante | Offset | Registre |
|-----------|--------|----------|
| SFR_PCON | 0x07 | Power control (bit 0 = HALT) |
| SFR_IE | 0x08 | Interrupt enable (bit 7 = EA master) |
| SFR_IP | 0x09 | Interrupt priority |
| SFR_T0PRR | 0x11 | Prescaler Timer 0 |
| SFR_T0L | 0x12 | Counter T0L courant (lecture) |
| SFR_T0LR | 0x13 | Reload T0L (écriture) |
| SFR_T0H | 0x14 | Counter T0H courant (lecture) |
| SFR_T0HR | 0x15 | Reload T0H (écriture) |
| SFR_T0CNT | 0x4E | Control, flags, enables Timer 0 |
| SFR_BTCR | 0x7F | Base Timer control |

---

## Todo

- [ ] Timer 0 Mode 1 (clock externe P72/P73)
- [ ] Timer 0 Mode 3 (conteur externe 16 bits)
- [ ] Timer 1 (tous modes)
- [ ] Fast-forward mode (BTCR7=1 → cycle = 64/fBST ≈ 2ms)
- [ ] Vecteur T1 (0x002B) + interrupt T1
- [ ] Nesting d'interruptions (interrupt_depth > 1)
