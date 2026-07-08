# Timers LC86K

## Implémenté

### Timer 0 Mode 2 (16-bit reload timer)

Mode actif quand `T0LONG=1`, `T0LEXT=0`.

**SFR utilisés :** T0PRR (0x111), T0L (0x112), T0LR (0x113), T0H (0x114), T0HR (0x115), T0CNT (0x14E)

**Comportement :**
- Vérification mode 2 et bits RUN (T0HRUN + T0LRUN) dans `tickTimer0()`
- Prescaler : `TPR = 256 - T0PRR`, accumulation dans `t0_prescaler_acc`
- Incrémentation 16-bit du compteur `T0H:T0L` avec wrapping (`+%=`)
- Détection d'overflow sur l'**ancienne** valeur (`old_l == 0xFF`)
- Overflow 16-bit → pose `T0HOVF | T0LOVF` dans T0CNT, reload depuis T0HR:T0LR
- `storeSFR` : reload au stop pour T0LR (si T0LRUN=0), T0HR (si T0HRUN=0), T0CNT (si RUN→stop)
- `loadSFR` : retourne `t0l_counter` / `t0h_counter` pour T0L/T0H (pas le reload)

### Base Timer (approximation cycles CPU)

**SFR utilisé :** BTCR (0x17F)

**Comportement :**
- Accumulation des cycles CPU dans `base_timer_acc`
- Tous les ~3 000 000 cycles (~0.5 s à 6 MHz), pose `BTCR.BT0_FLAG` (bit 1)
- Approximation volontaire : le vrai Base Timer utilise le quartz 32.768 kHz

### Boucle d'exécution

`tickTimers(cycles_used)` est appelé à la fin de `decode.step()`. Il délègue à :
- `tickTimer0(cycles_used)`
- `tickBaseTimer(cycles_used)`

### Fonctions ajoutées dans `Cpu`

| Fonction | Rôle |
|----------|------|
| `t0IsMode2()` | Vérifie T0LONG=1 et T0LEXT=0 |
| `tickTimer0(cycles)` | Avance Timer 0 si mode 2 + RUN actif |
| `incrementT0Mode2()` | Incrémente T0H:T0L, gère overflow + reload |
| `tickBaseTimer(cycles)` | Accumule cycles, pose flag BT0 à ~0.5 s |
| `tickTimers(cycles)` | Appelle tickTimer0 + tickBaseTimer |
| `servicePendingInterrupt()` | Stub vide (prêt à remplir) |

## Todo

### Interruptions timer

- [ ] Énumération `Interrupt` (int2_t0l, int3_base_timer, t0h, t1)
- [ ] Détection `pendingInterrupt()` (flag + enable local + IE + EA + interrupt_depth)
- [ ] Push PC + saut au vecteur (0x0013, 0x001B, 0x0023, 0x002B)
- [ ] `interrupt_depth` pour bloquer le nesting
- [ ] `interrupts_blocked` après écriture dans IE/IP
- [ ] `RETI` doit resetter `interrupt_depth = 0`

### Timer 0 Mode 0 (deux timers 8-bit indépendants)

- [ ] Mode actif quand `T0LONG=0`, `T0LEXT=0`. Chaque compteur (T0L, T0H) peut overflow indépendamment avec son propre flag et reload.

### HALT + réveil par interruption

- [ ] Quand `cpu.halted = true`, le CPU ne doit pas fetch d'instruction mais continuer à avancer les timers. Si une interruption devient pending, `cpu.halted = false` et l'IRQ est servie. Le Base Timer est souvent ce qui réveille le CPU.
