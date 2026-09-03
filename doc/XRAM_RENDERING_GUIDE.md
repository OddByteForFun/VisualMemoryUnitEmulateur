# Guide : Rendu XRAM réel du BIOS

## Vue d'ensemble

L'émulateur LC86000 affiche maintenant le **contenu réel bitmap d'XRAM** (la mémoire LCD) que le CPU écrit pendant l'exécution du BIOS et des jeux, au lieu d'un menu texte simplifié.

## Architecture du rendu

```
┌─────────────────────────────────────────┐
│ Boucle principale (main.zig)            │
├─────────────────────────────────────────┤
│ 1. Exécuter CPU : step(&cpu)            │
│ 2. Tracker BIOS : checkBiosPhase(&cpu)  │
│ 3. Gérer timers/IRQ                     │
│ 4. Affichage (beginDrawing)             │
│    ├─ renderLcd(&cpu)   ← XRAM bitmap   │
│    └─ drawText(status)  ← Debug info    │
└─────────────────────────────────────────┘
```

### Flux de données XRAM → Écran

```
1. CPU écrit dans XRAM (lc86K.zig::storeXram)
   └─> cpu.xram_banks.bank0[offset] = val
   
2. CPU écrit via VTRBF (lc86K.zig::storeSFR)
   └─> cpu.work_ram[addr] = val
   
3. Au rendu (main.zig::renderLcd)
   ├─ Pour chaque ligne y (0-31)
   │  ├─ Pour chaque byte x (0-5)
   │  │  └─ byte = getXramByte(cpu, y, x)
   │  │  └─ Pour chaque bit
   │  │     └─ rl.drawRectangle(...) si bit=1
   │  └─ Icônes (bank2) en bas
   └─> Affichage à l'écran (raylib)
```

## Organisation mémoire XRAM

```
XRAM = 198 bytes (2 × 96 + 6 icônes)

bank0[128]:  Lignes LCD  0-15 (16B/ligne, 6 bytes utiles)
             Entrelaçage:
             Offsets 0-5:   Ligne 0, row 0
             Offsets 6-11:  Ligne 0, row 1
             Offsets 12-17: Ligne 1, row 0
             ...
             
bank1[128]:  Lignes LCD 16-31 (même structure)
             
bank2[6]:    Icônes (6 bytes = 48 pixels × 1 ligne)
             Affichés en bas du LCD
```

**Calcul d'offset dans getXramByte():**
```zig
xram_row = y / 2          // Quel couple de lignes
row_in_pair = y % 2       // Laquelle du couple (0 ou 1)
offset = xram_row * 16 + row_in_pair * 6 + byte_col
         // xram_row*16 : saute les couples
         // row_in_pair*6 : décale de 6 bytes
         // byte_col : le byte demandé (0-5)
```

## Affichage de debug

La barre d'état en bas affiche :

```
PC=0x1234 ext=0x88 phase=mode_0 xram_wr=42
│         │        │            │
│         │        │            Nombre d'écritures XRAM
│         │        Phase BIOS actuelle (enum humain)
│         Registre EXT (sélecteur de banque instruction)
Pointeur d'instruction courant
```

### Phases BIOS

- `init` — Initialisation du CPU
- `clear_ram` — Effacement de la RAM
- `post_init` — Post-initialisation
- `date_wait` — Attente de la date RTC
- `lcd_setup` — Configuration de l'écran
- `date_ok` — Date validée
- `main_loop` — Boucle principale du BIOS
- `mode_0`, `mode_1`, `mode_2` — Écrans de menu (sélection du jeu)
- `game_launch` — Lancement du jeu
- `no_game` — Aucun jeu trouvé
- `game_running` — Le jeu exécute

## Cas d'usage

### Démarrage normal (avec BIOS + jeu)

```
$ ./zig-out/bin/lc86K roms/vmu_bios_jp.bin roms/game.vms

Rendu :
- Frame 0-100 : Écran noir (BIOS initialise)
- Frame 100-500 : Bitmap progressif du menu BIOS
- Frame 500-1000 : Menu complet (si visible)
- Frame 1000+ : Changement de phase (mode_0 → mode_1 → game_launch)
- Au lancement : Bascule vers flash0, nouveau bitmap du jeu
```

### Jeu seul (sans BIOS)

```
$ ./zig-out/bin/lc86K roms/game.vms

Rendu :
- Phase BIOS : skipped (phase = none)
- Affichage direct du bitmap du jeu
```

### Avec flag BIOS menu (compatibilité CLI)

```
$ ./zig-out/bin/lc86K roms/vmu_bios_jp.bin roms/game.vms --bios-menu

Même résultat que ci-dessus (flag accepté mais ne change plus le comportement)
```

## Débogage des écritures XRAM

Pour tracked les écritures, regarder le compteur `xram_wr` en bas de l'écran :

```zig
if (xram_write_count < 100) {
    // Peu d'écritures = le BIOS n'affiche rien
    // Vérifier : XBNK sélectionne-t-il les bonnes banques ?
}
```

### Diagnostic rapide

| Symptôme | Cause probable | Solution |
|----------|----------------|----------|
| Écran toujours noir | BIOS n'écrit pas dans XRAM | Vérifier `loadXram`/`storeXram` |
| `xram_wr=0` au BIOS | XRAM non modifié | Le BIOS ne trace pas le menu |
| Texte garbled | Entrelaçage incorrect | Revoir `getXramByte()` |
| Icônes manquantes | bank2 non écrite | Vérifier `XBNK=2` en BIOS |

## Améliorations futures

### 1. Capture de bitmap (debug)
```zig
// Sauvegarder le bitmap XRAM en PNG
fn dumpXramToPng(cpu: *Cpu, filename: []const u8) !void {
    // Convertir XRAM → pixels RGB → PNG
}
```

### 2. Simulation UI BIOS
Si le BIOS réel n'affiche rien :
```zig
// Recréer l'UI du menu BIOS graphiquement
fn simulateBiosMenuUI(cpu: *Cpu, phase: Cpu.BiosPhase) void {
    // Tracer manuellement le texte dans XRAM
}
```

### 3. Chassis VMU (visuel)
```zig
// Ajouter un bezel autour du LCD
fn drawVmuChassis(cpu: *Cpu, x: i32, y: i32) void {
    // Cadre physique, boutons, affichage LED
}
```

## Tests

Exécuter pour vérifier le rendu :
```bash
zig build
./zig-out/bin/lc86K roms/vmu_bios_jp.bin roms/Breakout.vms
```

Attendre que l'écran s'affiche progressivement selon les phases BIOS, puis le jeu lance.

## Références

- **XRAM layout** : lc86K.zig (struct Cpu, xram_banks)
- **Rendu** : main.zig (renderLcd, getXramByte)
- **Phases BIOS** : lc86K.zig (enum BiosPhase), debug.zig (checkBiosPhase)
- **Écritures XRAM** : lc86K.zig (storeXram, storeSFR SFR_VTRBF)
