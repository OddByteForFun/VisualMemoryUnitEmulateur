# LC86000

Émulateur du CPU **Sanyo LC86K87** — le processeur 8-bit de la VMU Dreamcast
(dite VMS), écrite en **Zig 0.16** avec rendu **raylib**.

## Caractéristiques matérielles émulées

| Composant | Détail |
|-----------|--------|
| CPU | 8-bit Sanyo LC86K87, ISA complète (70 instructions) |
| Horloge | 6 MHz externe (Dreamcast) ou RC/quartz temps réel (standalone, pilote par OCR) |
| RAM | 512B interne banquée (2×256B) + 198B XRAM LCD (2×96 + 6 icônes) |
| ROM | BIOS (64KB chargé, image boot réelle) |
| Flash | 128KB (200 blocs), FAT8, filesystem VMS |
| Affichage | 48×32 monochrome, rendu LCD raylib ×10 + bande icônes |
| Boutons | P3 active-low : Up/Down/Left/Right, A, B, MODE, Sleep |
| Timer | 1× Base (14-bit) + 2× Timer 16-bit |
| Série | Maple (Dreamcast) + synchro 8-bit (VMU-VMU) |

## Références de validation

- **libevmu** : la base de comparaison historique — filesystem flash/VMS,
  initialisation BIOS/RTC, logique de lancement jeu, gestion P3/IRQ.
- **DreamPotato** (émulateur .NET) : référence pour la sémantique du registre
  **EXT** (bascule de banque d'instructions `Ext0`/`Ext3`) et les valeurs SFR par défaut.
- **VMU.pdf** : documentation matérielle officielle (datasheet Sega).

## Utilisation

```
zig build run -- <game.vms> [options]
```

| Option | Effet |
|--------|-------|
| `<bios.bin> <game.vms>` | Fournir un BIOS explicite (sinon `roms/bios/` auto-détecté) |
| `--standalone` | Mode par défaut : horloge pilote par OCR (quartz), comme DreamPotato |
| `--docked` | Mode Dreamcast : 6 MHz horloge externe |
| `--azerty` | Mapping clavier AZERTY (A/B sur Q/Z/X) |
| `--bios-menu` | Activer le chemin menu BIOS (P7=0x02, non-standalone) |
| `--trace` | Trace des SFR et lectures P3 sur stderr |

### Contrôles

- **Flèches / WASD** : D-pad
- **Z/X (QWERTY) ou Q/Z (AZERTY)** : boutons A / B
- **Entrée / Espace** : Start (pulse sur écran titre)
- **M** : MODE (menu BIOS)
- **N** : Sleep (P3.7, en BIOS uniquement)

## État actuel

### Fait
- [x] CPU LC86K87 : ISA structurée et complète, validée par tests VMC
- [x] Boot BIOS + RTC + phases jusqu'au lancement du jeu (`bios_game_launch`)
- [x] Bascule de banque d'instructions via registre **EXT** (modèle `Ext0`/`Ext3`,
  corrigé et validé sur DreamPotato) — les appels BIOS GHEAD passent bien en ROM
- [x] Lancement réel du jeu en flash0 (PC=0x0000, banque committée)
- [x] Filesystem VMU / flash / FAT8 + installation d'un jeu
- [x] Rendu LCD 48×32 raylib (MCR bit3 + VCCR bit7 gated) + bande icônes
- [x] Boutons P3 : active-low, fronts, IRQ (bord + continu), menu BIOS
- [x] Interruptions : P3, timers, HALT/wake-up, priorités, RETI + restauration bank
- [x] Modes d'horloge OCR / ISL : 6 MHz (docked) vs quartz (standalone)
- [x] Tests : `zig build test` → **54/54** passent

## TODO

### P0 — comportement réel
- [ ] Valider l'expérience de jeu complète sur un titre réel (état : Tetris tourne,
      les titres GHEAD/BIOS-call démarrent après le correctif EXT)
- [ ] Cas limites MENU/START/MODE sur BIOS et écran titre

### P1 — périphériques
- [ ] I/O Ports P1 / P7 (états connexion, modes d'entrée)
- [ ] Maple MPLSW, MPLSTA, MPLRST
- [ ] Série SCON0/1, SBUF0/1, SBR
- [ ] Work RAM VRMAD, VTRBF

### P2 — simulation avancée
- [ ] PWM son via Timer 1
- [ ] Filesystem FAT8 — import/export VMS
- [ ] Compatibilité élargie aux ROM/jeux VMU

### P3 — qualité / entretien
- [ ] Nettoyer et documenter les points hérités
- [ ] Tests de comparaison BIOS/launch vs libevmu
- [ ] Captures de référence pour les boot VMU sensibles

## Documentation

- [doc/doc_inst.md](doc/doc_inst.md) — tableau ISA, avancement par opcode, tests VMC
- [doc/doc_timer.md](doc/doc_timer.md) — comportement des timers
- [doc/guide_technique.md](doc/guide_technique.md) — architecture et notes techniques