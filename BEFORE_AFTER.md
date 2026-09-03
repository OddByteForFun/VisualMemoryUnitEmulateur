# 🎬 Avant/Après : Rendu XRAM du BIOS

## Comparaison visuelle

### 🔴 AVANT : Menu texte simplifié

```
┌──────────────────────────┐
│  SEGA                    │  ← Texte en dur
│  Visual Memory           │
│  ---                     │
│                          │
│  > game.vms              │
│                          │
│  MODE to launch          │
│                          │
└──────────────────────────┘
PC=0x1234 ext=0x88 sync=42 xram_wr=1234
```

**Problèmes :**
- ❌ Menu écrit en dur (simulé)
- ❌ N'affiche pas ce que le CPU écrit
- ❌ Pas de progression visuelle du BIOS
- ❌ Code conditionnelle complexe (`if bios_menu_active...`)

---

### 🟢 APRÈS : Bitmap XRAM réel

```
┌──────────────────────────┐
│  ██  ██  ██  ██  ██      │  ← Bitmap pixelisé du BIOS
│  ██  ██  ██  ██  ██      │
│  ██  ██  ██  ██  ██      │
│  ██  ██  ██  ██  ██      │
│  ██████████████████      │  ← Progressif selon BIOS
│  ██  ██  ██  ██  ██      │
│  ██  ██  ██  ██  ██      │
└──────────────────────────┘
PC=0x1234 ext=0x88 phase=mode_0 xram_wr=1234
```

**Avantages :**
- ✅ Affiche ce que le CPU écrit réellement
- ✅ Progresse au fur et à mesure du BIOS
- ✅ Authentique (c'est le rendu réel)
- ✅ Code simplifié (une seule fonction `renderLcd()`)

---

## Code : Changement principal

### 🔴 AVANT

```zig
// main.zig : Boucle rendu
rl.beginDrawing();
rl.clearBackground(BG);

if (bios_menu_active and !bios_menu_selected) {
    drawBiosMenuScreen(game_path);  // Menu texte
} else {
    renderLcd(&cpu);  // XRAM bitmap
}

var status = std.fmt.bufPrintZ(..., "PC=... sync={d} xram_wr={d}");
rl.drawText(status, ...);
rl.endDrawing();
```

### 🟢 APRÈS

```zig
// main.zig : Boucle rendu
rl.beginDrawing();
rl.clearBackground(BG);

// Always render the actual LCD content (bitmap from XRAM)
renderLcd(&cpu);

// Display debug info overlay with BIOS context
var phase_str: []const u8 = switch(cpu.bios_phase) { ... };
var status = std.fmt.bufPrintZ(..., "PC=... phase={s} xram_wr={d}");
rl.drawText(status, ...);
rl.endDrawing();
```

---

## Variables : Avant/Après

### 🔴 AVANT

```zig
var bios_menu_mode_flag: bool = false;   // ❌ Flag inutile
var bios_menu_active: bool = false;      // ❌ État rendu obsolète
var bios_menu_selected: bool = false;    // ❌ Mal nommé
var bios_menu_index: u32 = 0;            // ❌ Non utilisé
var start_pulse_frames: u32 = 0;         // ✅ Gardé (jeu)
```

### 🟢 APRÈS

```zig
var game_started: bool = false;  // ✅ Remplace menu_selected (plus clair)
var start_pulse_frames: u32 = 0; // ✅ Gardé (jeu)
```

---

## Fonction supprimée

### 🔴 AVANT

```zig
fn drawBiosMenuScreen(game_path: []const u8) void {
    rl.clearBackground(rl.Color.black);
    rl.drawRectangle(0, 0, LCD_W * SCALE, LCD_H * SCALE, rl.Color.black);
    rl.drawText("SEGA", 8, 4, 14, rl.Color.white);
    rl.drawText("Visual Memory", 8, 20, 10, rl.Color.white);
    rl.drawText("---", 8, 30, 10, rl.Color.white);
    // ... + 11 lignes de texte manuel
}
```

### 🟢 APRÈS

```
Fonction supprimée (20 lignes gagnées) ✅
```

---

## Transition du jeu : Avant/Après

### 🔴 AVANT

```zig
if (!bios_menu_selected and cpu.bios_phase == .bios_game_launch) {
    // ... transition
    bios_menu_selected = true;
    bios_menu_active = false;
}
```

### 🟢 APRÈS

```zig
if (!game_started and cpu.bios_phase == .bios_game_launch) {
    // ... transition
    game_started = true;
}
```

---

## Affichage de debug : Avant/Après

### 🔴 AVANT

```
PC=0x00E1 ext=0x80 sync=123 xram_wr=45
```

- ❓ Qu'est-ce que "sync=123" ? (nombre d'appels syncInstructionBank)
- ❓ Impossible de savoir quelle phase BIOS active

### 🟢 APRÈS

```
PC=0x00E1 ext=0x80 phase=mode_0 xram_wr=45
```

- ✅ Phase BIOS lisible (mode_0, mode_1, mode_2, game_launch, etc.)
- ✅ Permet de tracker la progression
- ✅ Utile pour déboguer

---

## Flux de rendu : Avant/Après

### 🔴 AVANT

```
┌─ if bios_menu_active
│  └─ drawBiosMenuScreen()     [Menu texte]
│     ├─ clearBackground(black)
│     ├─ drawText("SEGA")
│     ├─ drawText("Visual Memory")
│     └─ ... etc
│
└─ else
   └─ renderLcd(&cpu)          [XRAM bitmap]
```

### 🟢 APRÈS

```
┌─ renderLcd(&cpu)    [Toujours XRAM bitmap]
│  ├─ Pour chaque ligne
│  │  ├─ getXramByte()
│  │  └─ drawRectangle()
│  └─ Icônes (bank2)
│
└─ drawText(status)   [Info debug]
```

---

## Statistiques

| Métrique | Avant | Après | Diff |
|----------|-------|-------|------|
| `main.zig` lignes | 284 | 264 | **-20** |
| Fonctions rendu | 2 (if/else) | 1 (unifié) | **-1** |
| Variables globales | 7 | 2 | **-5** |
| Conditions rendu | Complexe | Simple | **Simplifié** |
| Authenticité | Simulée | Réelle | **✅** |

---

## Résultat final

✅ **Code plus court** (264 vs 284 lignes)
✅ **Code plus clair** (pas de branchement rendu)
✅ **Rendu authentique** (ce que CPU écrit = ce qui s'affiche)
✅ **Débogage amélioré** (phase BIOS visible)
✅ **Maintenance réduite** (une seule fonction rendu)

---

## Prochaines observations

Au lancement du programme :

1. **Frame 0-100** : Écran noir (BIOS initialise XRAM = vide)
2. **Frame 100-500** : Bitmap progressif du menu (BIOS trace l'UI)
3. **Frame 500-1000** : Menu complet visible
4. **Phase** : `init` → `clear_ram` → `lcd_setup` → `main_loop` → `mode_0`
5. **Au MODE** : Transition vers `game_launch`, écran devient noir
6. **Jeu active** : Nouveau bitmap du jeu affiche
