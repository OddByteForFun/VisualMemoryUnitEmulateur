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

## Référence de comparaison

La base de comparaison principale est libevmu : c'est le point de référence le plus utile pour valider le comportement matériel du VMU, en particulier pour :

- la structure du filesystem flash et du volume VMS,
- l'initialisation BIOS/RTC au boot,
- la logique de lancement d'un jeu depuis la ROM BIOS vers la flash,
- la gestion de P3 (boutons, front, IRQ),
- les priorités d'interruption et la réactivation après HALT.

Le projet essaie de rester proche du comportement réel observé dans libevmu, sans copier aveuglément son code, mais en validant les séquences de boot et les états matériels.

## Documentation

Les références seront effectuées d'après le fichier VMU.pdf et les comportements observés dans libevmu.

### Instructions

Source : [doc/doc_inst.md](doc/doc_inst.md)
Tableau complet des 70 instructions, état d'avancement par opcode, résumé des tests VMC.

### Timers

Source : [doc/doc_timer.md](doc/doc_timer.md)

## État actuel du projet

### Core CPU / BIOS / Jeu
- [x] CPU LC86K87 principale et décodage ISA
- [x] Table ISA structurée et cohérente, avec tests de couverture
- [x] Implémentation des instructions restantes et validation par tests VMC
- [x] Boot BIOS + initialisation RTC
- [x] Filesystem VMU / flash / FAT avec installation d'un jeu dans la flash
- [x] Transitions de phase BIOS jusqu'au lancement du jeu
- [x] Bascule d'instruction vers flash0 lors du lancement réel
- [x] Gestion des boutons P3 avec logique active-low et front d'IRQ
- [x] Interruption P3, timer, HALT, wake-up et priorités
- [x] 92/92 tests passés via `zig build test`

### Validation
```
zig build test
Build Summary: 3/3 steps succeeded; 92/92 tests passed
```

## TODO

### P0 — stabilisation du comportement réel
- [x] Vérifier les phases BIOS jusqu'à `bios_game_launch`
- [x] Couvrir la logique de lancement réel depuis le BIOS vers flash0
- [x] Reprendre la référence libevmu pour la sémantique des boutons / IRQ / launch
- [ ] Valider l'expérience de jeu complète en runtime sur un jeu réel et comparer visuellement au comportement attendu
- [ ] Vérifier les cas limites de MENU/START/MODE sur BIOS et sur écran titre du jeu

### P1 — périphériques et matériel VMU
- [ ] I/O Ports P1, P3, P7 — boutons, état connexion, modes d'entrée
- [ ] Contrôle LCD XBNK, VCCR, MCR, CNR, TDR
- [ ] Contrôle horloge OCR, ISL, division d'horloge
- [ ] Maple MPLSW, MPLSTA, MPLRST
- [ ] Série SCON0/1, SBUF0/1, SBR
- [ ] Flash FPR, EXT (bank switching)
- [ ] Work RAM VRMAD, VTRBF
- [ ] Power PCON (halt)

### P2 — fonctionnalités de simulation plus avancées
- [ ] Affichage 48×32 depuis XRAM
- [ ] PWM son via Timer 1
- [ ] Maple Bus (communication Dreamcast)
- [ ] Filesystem Flash FAT8 (import/export VMS)
- [ ] Compatibilité plus large avec l'ensemble des ROM/jeux VMU

### P3 — qualité / maintenance
- [ ] Nettoyer et documenter les points d'implémentation encore hérités
- [ ] Ajouter des tests de comparaison sur séquences BIOS/launch libevmu
- [ ] Ajouter des captures de référence pour les cas les plus sensibles du boot VMU

