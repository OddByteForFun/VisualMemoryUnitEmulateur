# Projet

"Le Dreamcast VMU est une carte mémoire développée par l'entreprise Sega comportant un écran LCD pour pouvoir jouer à des mini-jeux mais aussi voir des animations lors de parties jouées sur Dreamcast. Son nom original est Dreamcast VMS pour Visual Memory System." Source : Wikipedia

## Caractéristiques matérielles

| Composant | Détail |
|-----------|--------|
| CPU | 8-bit Sanyo LC86K87 |
| Horloge | 6 MHz (céramique) + 32.768 kHz (quartz RTC) |
| RAM | 512B interne banquée (2×256B) + 198B XRAM LCD (2×96 + 6 icônes) |
| ROM | 16KB BIOS |
| Flash | 128KB (200 blocs), FAT8 |
| Affichage | 48×32, monochrome |
| Son | PWM 1 canal 8-bit |
| Entrées | D-pad 4 dir. + A, B, MODE, SLEEP |
| Timer | 1× Base (14-bit) + 2× Timer 16-bit |
| Série | Maple (Dreamcast) + synchro 8-bit (VMU-VMU) |

## Documentation  
Les références seront effectuées d'après le fichier VMU.pdf  

### Instructions

Source : [doc/doc_inst.md](doc/inst.md) 
Tableau complet des 70 instructions, état d'avancement par opcode, résumé des tests VMC.  
68/70 instructions implémentées 🟢, 67 avec test, 1 à ajouter (callr).

```
zig build test --summary all
Build Summary: 3/3 steps succeeded; 92/92 tests passed
test success
└─ run test 92 pass (92 total) 22ms MaxRSS:4M
   └─ compile test Debug native cached 53ms MaxRSS:21M
```

### Timers

Source : [doc/doc_timer.md](doc/timer.md)

- [x] Timer 0 Mode 2 (16-bit reload, prescaler, overflow, reload au stop), Base Timer (flag BT0 ~0.5s), tick câblé dans `decode.step()`.
- [x] Interruptions timer (`servicePendingInterrupt` : priorités int2→int3→t0h→t1→p3→maple, gate EA, blocage post-écriture IE/IP, skip post-RETI façon libevmu), Timer 0 Mode 0 (T0L/T0H 8-bit indépendants, prescaler 256−T0PRR), HALT + réveil par interruption. Comportement verrouillé par tests (92/92).

## TODO

### Instructions (P0)
- [x] Tests VMC pour les instructions non couvertes
- [x] Implémenter `servicePendingInterrupt()` + constantes IE
- [x] Timer 0 Mode 0 (deux 8-bit indépendants)
- [x] HALT + réveil par interruption

### Périphériques (P1)
- [ ] I/O Ports P1, P3, P7 — boutons, état connexion
- [ ] Contrôle LCD XBNK, VCCR, MCR, CNR, TDR
- [ ] Contrôle Horloge OCR, ISL, division d'horloge
- [ ] Interruptions complètes (10 sources, priorités)
- [ ] Maple MPLSW, MPLSTA, MPLRST
- [ ] Série SCON0/1, SBUF0/1, SBR
- [ ] Flash FPR, EXT (bank switching)
- [ ] Work RAM VRMAD, VTRBF
- [ ] Power PCON (halt)

### Périphériques (P2)
- [ ] Affichage 48×32 depuis XRAM
- [ ] PWM son via Timer 1
- [ ] Maple Bus (communication Dreamcast)
- [ ] Filesystem Flash FAT8 (import/export VMS)

