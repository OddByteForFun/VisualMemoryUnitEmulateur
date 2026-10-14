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
zig build run -- [<game.vms>] [options]
```

| Option | Effet |
|--------|-------|
| `[<game.vms>]` | Jeu à charger en Flash (optionnel : sans jeu, la VMU démarre en mode autonome BIOS) |
| `<bios.bin> <game.vms>` | Fournir un BIOS explicite (sinon `roms/bios/vmu_bios_jp.bin` auto-détecté) |
| `--bios-menu` / `-m` | Forcer le démarrage dans le menu BIOS officiel même si un jeu est chargé |
| `--set-time` | Démarrer sur l'écran officiel de configuration de l'horloge et de la date du BIOS |
| `--standalone` | Mode par défaut : horloge pilotée par OCR (quartz), comme le vrai matériel |
| `--docked` | Mode Dreamcast : 6 MHz horloge externe |
| `--azerty` | Mapping clavier AZERTY (ZSQD pour le D-pad, W/X pour A/B) |
| `--trace` | Trace des SFR et lectures P3 sur stderr |

### Contrôles

- **Flèches / WASD (QWERTY) / ZSQD (AZERTY)** : D-pad (navigation menus et jeux)
- **Entrée / Espace / Z (QWERTY) / W (AZERTY) / K** : Bouton A (validation / action)
- **X / Backspace / L** : Bouton B (annulation / retour)
- **M / Tab** : Bouton MODE (basculer entre Horloge, Fichiers et Jeu dans le BIOS)
- **N** : Bouton Sleep (P3.7)
- **Échap / F1** : Soft-reset immédiat vers le menu BIOS officiel

## État actuel

### Fait
- [x] CPU LC86K87 : ISA structurée et complète, validée par tests VMC
- [x] Boot BIOS officiel, détection des phases et menu interactif
- [x] Navigation BIOS complète : Horloge temps réel, Gestionnaire de fichiers, écran réglage date
- [x] Émulation Audio PWM Buzzer via Timer 1 et flux Raylib
- [x] Bascule de banque d'instructions via registre **EXT** (`Ext0`/`Ext3`)
- [x] Lancement réel du jeu en flash0 depuis le BIOS ou en auto-boot
- [x] Filesystem VMU / flash / FAT8 + parseur d'en-tête VMS / VMI officiel
- [x] Rendu LCD 48×32 raylib avec défilement STAD et colonnes mortes XRAM
- [x] Boutons P3 complets (active-low, D-pad, A, B, MODE, Sleep) + reset BIOS
- [x] Modes d'horloge OCR / ISL : 6 MHz (docked) vs quartz (standalone)
- [x] Tests : `zig build test` → **100/100** passent

## TODO

### P0 — comportement réel
- [ ] Valider l'expérience de jeu complète sur les titres à sauvegarde (Shenmue, etc.)
- [ ] Persistance de l'image Flash sur disque à la fermeture

### P1 — périphériques
- [ ] Contrôleur d'interruptions hiérarchique avec registre `IP` (priorités Low/High)
- [ ] I/O Ports P1 / P3 : distinction Read-Latch vs Read-Pin sur instructions RMW
- [ ] Maple MPLSW, MPLSTA, MPLRST (communication bus Dreamcast)
- [ ] Série SCON0/1, SBUF0/1, SBR (VMU-to-VMU)

### P2 — simulation avancée
- [x] PWM son via Timer 1
- [x] Filesystem FAT8 — parseur VMS / VMI
- [ ] Rendu LCD avec contraste VCCR et rémanence physique (ghosting)

### P3 — qualité / entretien
- [ ] Nettoyer et documenter les points hérités
- [ ] Tests de comparaison BIOS/launch vs libevmu
- [ ] Captures de référence pour les boot VMU sensibles

## Documentation

- [doc/doc_inst.md](doc/doc_inst.md) — tableau ISA, avancement par opcode, tests VMC
- [doc/doc_timer.md](doc/doc_timer.md) — comportement des timers
- [doc/guide_technique.md](doc/guide_technique.md) — architecture et notes techniques