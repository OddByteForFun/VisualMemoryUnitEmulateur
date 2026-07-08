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

## Instructions

👉 Voir [doc/doc_inst.md](doc/inst.md) — tableau complet des 70 instructions, état d'avancement par opcode, résumé des tests VMC.

**Résumé :** 68/70 instructions implémentées 🟢, 53 avec test VMC, 15 tests à ajouter.

## Timers

👉 Voir [doc/doc_timer.md](doc/timer.md) — statut détaillé de l'implémentation timer.

**Implémenté :** Timer 0 Mode 2 (16-bit reload, prescaler, overflow, reload au stop), Base Timer (flag BT0 ~0.5s), tick câblé dans `decode.step()`.

**En attente :** Interruptions timer (stub `servicePendingInterrupt` prêt), Timer 0 Mode 0, HALT + réveil.

## TODO

### Instructions (P0)
- [ ] Tests VMC pour les 15 instructions non couvertes
- [ ] Implémenter `servicePendingInterrupt()` + constantes IE
- [ ] Timer 0 Mode 0 (deux 8-bit indépendants)
- [ ] HALT + réveil par interruption

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

