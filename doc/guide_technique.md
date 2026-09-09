# Guide technique pédagogique — LC86000 (Émulateur VMU Dreamcast)

> Ce document explique, en partant de zéro, comment fonctionne cet émulateur du CPU
> **Sanyo LC86K87** (le processeur 8-bit du VMU Dreamcast). Il a été écrit pour quelqu'un
> qui **ne connaît ni le code ni Zig** : on y aborde donc aussi les idiomes Zig rencontrés.
>
> Trois thèmes sont traités en profondeur car ce sont les briques les plus subtiles du projet :
> 1. **Les timers** (Timer 0, Timer 1, Base Timer)
> 2. **Les interruptions** (le mécanisme qui fait réagir le CPU aux timers et aux boutons)
> 3. **Le système de fichiers flash VMU/FAT** (comment un jeu est stocké et retrouvé)
>
> Les sujets non développés dans ce projet ne sont **pas** décrits ici (ex. son PWM, bus Maple complet).

---

## Table des matières

- [1. Le contexte : qu'est-ce qu'on émule ?](#1-le-contexte-quest-ce-quon-mule)
- [2. Vue d'ensemble de l'architecture](#2-vue-densemble-de-larchitecture)
- [3. Les bases de Zig nécessaires à la lecture](#3-les-bases-de-zig-ncessaires--la-lecture)
- [4. Le déroulement du démarrage](#4-le-droulement-du-dmarrage)
- [5. L'espace mémoire et les SFRs](#5-lespace-mmoire-et-les-sfrs)
- [6. Les timers en profondeur](#6-les-timers-en-profondeur)
- [7. Les interruptions en profondeur](#7-les-interruptions-en-profondeur)
- [8. Le système de fichiers flash VMU/FAT](#8-le-systme-de-fichiers-flash-vmufat)
- [9. Le BIOS : son rôle, ses phases et le lancement du jeu](#9-le-bios-son-rle-ses-phases-et-le-lancement-du-jeu)
- [10. Les boutons P3 et le rendu LCD](#10-les-boutons-p3-et-le-rendu-lcd)
- [11. La boucle d'émulation pas à pas](#11-la-boucle-dmulation-pas--pas)
- [12. Les tests](#12-les-tests)

---

## 1. Le contexte : qu'est-ce qu'on émule ?

Le **VMU** (Visual Memory Unit) de la Dreamcast est une carte mémoire avec un petit écran
LCD 48×32 pixels. On peut y jouer à de mini-jeux. À l'intérieur se trouve un CPU 8-bit :
le **Sanyo LC86K87**.

Au lieu de fabriquer la puce, on la **recrée en logiciel** : c'est un émulateur. Le programme
suit à la lettre le comportement décrit dans le manuel matériel `doc/VMU.pdf`.

Ce qui est reproduit ici :

| Élément | Ce qui est émulé |
|---------|------------------|
| CPU LC86K87 | Les 70 instructions, les registres, l'adressage |
| Mémoire | 512B de RAM, 198B de XRAM (écran), SFRs |
| Timers | Timer 0, Timer 1, Base Timer (RTC 32.768 kHz) |
| Interruptions | Vecteurs INT2, INT3, T0H, T1, P3 |
| Flash | 128 KB organisée en FAT VMU (système de fichiers) |
| Entrées | Le d-pad et les boutons A/B/MODE/SLEEP via le clavier |
| Écran | Le LCD 48×32 rendu avec la bibliothèque **raylib** |

Le BIOS (ROM) est chargé, le jeu VMS est « installé » dans la flash, et l'émulateur fait
tourner le BIOS réel qui va lui-même lancer le jeu — exactement comme sur une vraie VMU.

---

## 2. Vue d'ensemble de l'architecture

Les fichiers du projet et leur rôle :

| Fichier | Rôle |
|---------|------|
| `main.zig` | Point d'entrée, boucle principale, rendu LCD, entrées clavier |
| `lc86K.zig` | **Le cœur** : définition du CPU, des registres, de la mémoire, des timers et interruptions |
| `decode.zig` | Le **décodeur/exécuteur** : lit un opcode et exécute l'instruction |
| `isa.zig` | La **table** des 256 opcodes (source unique de vérité de l'encodage) |
| `timer.zig` | La logique des timers (séparée pour être testable) |
| `vmu.zig` | La logique VMU : création du système de fichiers flash, RTC BIOS |
| `debug.zig` | Journalisation, désassemblement, détection de boucles |
| `tests.zig` | 92 tests unitaires |

### Le flux général

```
main.zig
  │
  ├── Cpu.init(rom)       → crée le CPU vide
  ├── vmu.initVmuFlash()  → crée le système de fichiers dans la flash
  ├── vmu.installGame()   → « grave » le jeu dans la flash + entrée de répertoire
  ├── cpu.reset()         → remet le CPU à l'état de démarrage
  ├── vmu.initBiosRtc()   → pré-règle la date RTC du BIOS
  │
  └── boucle infinie (60 images/seconde)
        │
        ├── updateButtons(&cpu)          → clavier → boutons P3
        │
        └── 100 000 fois par image :
              └── decode.step(&cpu)      → exécute UNE instruction
```

Le point clé : **une « image » (60 fois par seconde) contient 100 000 pas de CPU**.
Chaque `step()` exécute une instruction et fait avancer les timers d'autant de cycles.
C'est dans cette mécanique que timers et interruptions prennent vie.

### La logique de fonctionnement entre les fichiers

Au-delà des rôles individuels, il faut comprendre **qui appelle qui** et **où circule la
donnée**. C'est ce qui relie les fichiers entre eux.

#### Le graphe des dépendances (imports)

Chaque fichier Zig commence par des `@import` qui déclarent ses dépendances. Voici le graphe
de circulation :

```
                ┌─────────────┐
                │   isa.zig   │  (la table, source de vérité)
                └──────┬──────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        ▼              ▼              ▼
  ┌──────────┐   ┌──────────┐   ┌──────────┐
  │ debug.zig│   │decode.zig│   │  vmu.zig │
  └────┬─────┘   └────┬─────┘   └────┬─────┘
       │              │              │
       │              ▼              │
       │        ┌──────────┐         │
       └───────►│ lc86K.zig│◄────────┘
                │  (Cpu)   │
                └────┬─────┘
                     │
                     ▼
              ┌──────────┐
              │ timer.zig│
              └──────────┘
```

Lecture de ce graphe :

- **`isa.zig`** ne dépend de personne — il est la base. `decode.zig`, `debug.zig` et
  `vmu.zig` l'importent pour connaître l'encodage des instructions.
- **`decode.zig`, `debug.zig`, `vmu.zig`** dépendent tous de **`lc86K.zig`** (le `Cpu`).
  C'est le cœur : tous les autres lisent/mutent la structure `Cpu`.
- **`lc86K.zig`** délègue la logique des timers à **`timer.zig`** (`Cpu.tickTimers()` appelle
  `timer.tick()`). Ce lien est dans `lc86K.zig:244`.
- **`main.zig`** (non représenté pour la lisibilité) importe `lc86K`, `decode`, `debug`,
  `vmu` et `raylib`. C'est lui qui orchestre tout au démarrage et dans la boucle.

> **Remarque cycles d'import** : `lc86K.zig` importe `timer.zig`, et `timer.zig` importe
> `lc86K.zig` (pour accéder au type `Cpu` et à ses constantes). Cette dépendance **circulaire**
> est permise par le système de modules de Zig (voir `build.zig`), qui gère ça proprement.
> Sans les modules, il aurait fallu casse la boucle d'une façon ou d'une autre.

#### Les dépendances configurées dans `build.zig`

Ces liens ne sont pas magiques : ils sont **déclarés** dans `build.zig`, qui crée les
« modules » et leurs imports :

```zig
const lc86K_mod = b.createModule(.{ .root_source_file = b.path("lc86K.zig"), ... });
const timer_mod = b.createModule(.{ .root_source_file = b.path("timer.zig"), ... });

timer_mod.addImport("lc86K", lc86K_mod);
lc86K_mod.addImport("timer", timer_mod);      // dépendance circulaire déclarée
```

Chaque fichier « voit » les autres par le nom d'import donné ici (`timer` pour timer.zig,
`lc86K` pour lc86K.zig, etc.).

#### Le chemin d'un appel complet (une instruction)

Suivons la vie d'une seule instruction, du clavier à l'écran, en traversant tous les fichiers :

```
[main.zig]  boucle image
   │
   ├─ updateButtons(cpu)            [main.zig]
   │    └─ lit le clavier raylib
   │    └─ écrit cpu.p3_buttons     (écrit dans la struct Cpu via pointeur)
   │    └─ gère P3INT (boutons)
   │
   └─ step(cpu)                     [decode.zig]
        ├─ cpu.fetch8()             [lc86K.zig]  lit l'opcode
        ├─ decodeOpcode()           [decode.zig] → table isa.TABLE [isa.zig]
        ├─ exécute switch(inst)     [decode.zig] → lit/écrit via cpu.load8/store8 [lc86K.zig]
        ├─ cpu.tickTimers(used)     [lc86K.zig]
        │    └─ timer.tick()        [timer.zig]  met à jour les compteurs dans cpu
        ├─ cpu.requestLevelDrivenInterrupts()   [lc86K.zig]
        ├─ cpu.servicePendingInterrupt()        [lc86K.zig]  peut pousser PC sur la pile
        └─ (retour)
   │
   └─ renderLcd(cpu)                [main.zig]
        └─ lit cpu.xram_banks … dessine les pixels [raylib]
```

Ce qui ressort : **`decode.zig` est le « chef d'orchestre » de chaque pas**, mais tout l'état
vit dans la struct `Cpu` (`lc86K.zig`). Les autres fichiers ne font que lire/muter ce Cpu.

#### Le rôle des pointeurs (pourquoi `&cpu` partout)

Quand on voit `updateButtons(&cpu)` ou `step(&cpu)`, le `&` signifie « **passe l'adresse** du
CPU ». Cela permet à la fonction de **modifier** le même cpu. Si on passait `cpu` sans `&`,
on modifierait une **copie** (Zig passe par valeur), et les changements seraient perdus.

```
function(cpu)       → reçoit une COPIE → modifs perdues
function(&cpu)      → reçoit l'ADRESSE (pointeur *Cpu) → modifs conservées
```

C'est ce mécanisme qui lie tous les fichiers entre eux : le `*Cpu` qui circule est le
« contrat » partagé par tout le projet.

#### Le flux de données principal en une phrase

> Le clavier (raylib) → `updateButtons` → `cpu.p3_buttons` → le CPU le lit via le port P3 →
> l'exécution (`decode`) fait avancer les timers (`timer`) → les timers posent des flags →
> `servicePendingInterrupt` déclenche des IRQ → le BIOS/jeu réagit → l'écran est rempli dans
> la XRAM → `renderLcd` l'affiche.

Tout ce flux de données passe par la **struct `Cpu`**, qui est le centre de gravité du projet.

---

## 3. Les bases de Zig nécessaires à la lecture

Si vous ne connaissez pas Zig, voici ce dont vous avez besoin pour suivre le code. On
ne fait que l'essentiel — le reste se comprend par le contexte.

### 3.1 Les types d'entiers

Zig a des types avec une largeur **explicite** :

| Type | Largeur | Signé ? | Exemple de valeur |
|------|---------|---------|-------------------|
| `u8` | 8 bits | non | 0 à 255 |
| `u16` | 16 bits | non | 0 à 65 535 |
| `u32` | 32 bits | non | 0 à ~4 milliards |
| `i8` | 8 bits | oui | -128 à 127 |
| `u9` | 9 bits | non | 0 à 511 (espace d'adressage du CPU !) |
| `u17` | 17 bits | non | adresse flash |

L'avantage : le type dit **exactement** combien de bits on veut. Par exemple l'adresse
mémoire du LC86K tient sur 9 bits → type `u9`.

### 3.2 L'opérateur `+%` (addition saturante)

Le préfixe `%` indique une opération **wrap-around** (on laisse déborder le compteur) :

```zig
var x: u8 = 255;
x +%= 1;  // x redevient 0 (255 + 1 = 256 → tronqué à 0)
```

C'est exactement le comportement d'un CPU 8-bit : un registre de 8 bits qui reçoit 255+1
redevient 0. On retrouve `+%=`, `-%=` partout pour simuler fidèlement l'arithmétique 8-bit.

### 3.3 `@intCast`, `@truncate`, `@bitCast`, `@as`

Ce sont des fonctions de conversion de types **explicites** (Zig est très stricte) :

- `@as(u16, x)` : « considère `x` comme un `u16` » (assertion de type)
- `@intCast(x)` : convertit un entier d'une largeur vers une autre (la valeur doit rentrer)
- `@truncate(x)` : **tronque** (coupe) les bits de poids fort pour tenir dans la cible
- `@bitCast(x)` : réinterprète les mêmes bits sous un autre type

```zig
const a17: u17 = @as(u17, self.trl) | (@as(u17, self.trh) << 8);
```

Ici on assemble `trl` (8 bits) et `trh` (8 bits) pour former une adresse flash de 17 bits.

### 3.4 Pointeurs et structures

- `*Cpu` : **pointeur** vers une structure `Cpu` (on passe le CPU par référence pour le modifier)
- `self : *Cpu` dans une méthode : analogue au `this` de Java/Python
- Le `.` accède aux champs : `cpu.pc`, `cpu.halted`, etc.

### 3.5 `enum`, `packed struct`, `const`

- `enum` : un ensemble de valeurs nommées (ex. les modes d'adressage, les types d'IRQ)
- `packed struct` : une structure dont les champs occupent exactement les bits donnés.
  Exemple : le registre PSW (octet de flags) :

```zig
pub const Psw = packed struct(u8) {
    p: bool = false,      // bit 0
    rambk0: bool = false, // bit 1
    ov: bool = false,     // bit 2
    ac: bool = false,     // bit 6
    cy: bool = false,     // bit 7
};
```

Zig vous laisse manipuler les flags comme des `bool`, mais les range dans les bits d'un octet.

### 3.6 `switch` et union

```zig
switch (dec.inst) {
    .nop => {},
    .br => { ... },
    .add_imm, .add_d9, .add_ri => { ... },
}
```

C'est un `switch` sur une valeur d'énumération. Plusieurs cas peuvent partager la même
branche (ici toutes les variantes de `ADD`).

### 3.7 `orelse`, `catch`, `if`-expression

Zig traite les expressions « nullable » (qui peuvent ne rien valoir) :

```zig
_path_a orelse { std.debug.print("Usage...", .{}); return; };
```

Si `path_a` vaut `null`, on exécute le bloc (on affiche l'aide et on sort).

`catch` est l'équivalent pour les erreurs. `std.fmt.bufPrintZ(...) catch "??"` :
si le formatage échoue, on renvoie la chaîne `"??"`.

### 3.8 Les tests avec `test`

```zig
test "ADD immediate VMC-156" {
    // ... setup ...
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x68), cpu.a);
}
```

Chaque bloc `test "..."` est un test autonome. On lance tout avec `zig build test`.

---

## 4. Le déroulement du démarrage

Regardons `main()` en détails.

### 4.1 Parsing des arguments

```zig
while (arg_iter.next()) |arg| {
    if (std.mem.eql(u8, arg, "--azerty")) {
        azerty_mode = true;
    } else if (std.mem.eql(u8, arg, "--bios-menu")) {
        bios_menu_mode_flag = true;
    } else if (path_a == null) {
        path_a = arg;
    } else if (path_b == null) {
        path_b = arg;
    }
}
```

On lit la ligne de commande. Deux chemins possibles :

- **1 fichier** : c'est le jeu, le BIOS est cherché automatiquement dans `roms/vmu_bios_jp.bin`
- **2 fichiers** : le premier est le BIOS, le second le jeu

```zig
const bios_path = if (path_b != null) path_a.? else "roms/vmu_bios_jp.bin";
const game_path = if (path_b) |b| b else path_a.?;
```

> L'expression `if (x) |b| b` est le « déballage » d'une option : si `x` contient une valeur,
> on la met dans `b`. C'est le idiome Zig pour traiter les valeurs optionnelles proprement.

### 4.2 Chargement du BIOS dans la ROM

```zig
const rom = init.arena.allocator().alloc(u8, 65536) catch unreachable;
@memset(rom, 0);
const bios_size = try bios_file.readPositionalAll(init.io, rom[0..65536], 0);
```

On alloue **64 Ko** (65 536 octets), on les met à zéro, puis on lit le fichier BIOS dedans.
La ROM du CPU fait 64 Ko.

### 4.3 Création du CPU et de la flash

```zig
var cpu = Cpu.init(rom);
vmu.initVmuFlash(&cpu);            // crée le système de fichiers VMU
const game_size = try game_file.readPositionalAll(init.io, cpu.flash[0..65536], 0);
vmu.installGame(&cpu, game_size);  // installe le jeu dans la flash
```

On crée le CPU, on initialise la flash avec un système de fichiers valide, on charge le jeu
dans les 64 premiers Ko de la flash, puis on crée l'entrée de répertoire et la chaîne FAT qui
pointent vers le jeu. Tout le §8 est consacré à cette partie.

### 4.4 Reset du CPU et RTC

```zig
cpu.reset();
vmu.initBiosRtc(&cpu, use_bios_menu);
```

`reset()` remet le CPU dans l'état « à la mise sous tension » (PC=0, registres=0, SFRs aux
valeurs par défaut du matériel). `initBiosRtc()` pré-règle la date et saute par-dessus le
code du BIOS qui attendrait une réponse de la Dreamcast (qu'on n'émule pas) en positionnant
`pc = 0x2E1`.

---

## 5. L'espace mémoire et les SFRs

### 5.1 Vue de la mémoire

Le LC86K adresse **512 emplacements** (9 bits, 0x000 à 0x1FF) pour la RAM/données directes :

| Plage | Contenu |
|-------|---------|
| `0x000` – `0x0FF` | RAM 256B — **banque 0** (système + pile) ou **banque 1** (selon `PSW.rambk0`) |
| `0x100` – `0x17F` | **SFRs** : registres de fonction spéciale (timers, ports, contrôle) |
| `0x180` – `0x1FF` | **XRAM** : mémoire de l'écran LCD (3 banques) |

### 5.2 Le routage dans `load8` / `store8`

C'est dans `lc86K.zig` que toute lecture est routée vers la bonne mémoire :

```zig
pub fn load8(self: *Cpu, addr: u9) u8 {
    const result = switch (addr) {
        0...0xFF  => self.currentRamBank()[addr],
        0x100...0x17F => self.loadSFR(@as(u7, @truncate(addr - 0x100))),
        0x180...0x1FF => self.loadXram(@as(u7, @truncate(addr - 0x180))),
    };
    return result;
}
```

Selon la plage d'adresse, on lit la RAM, un SFR ou la XRAM. Notez le **`switch` sur plage**
de valeurs (`0...0xFF`), une feature pratique de Zig.

### 5.3 Les SFRs — registres de fonction spéciale

Les SFRs sont les « boutons de contrôle » du matériel. Voici les plus importants pour
la suite :

| Constante | Offset | Rôle |
|-----------|--------|------|
| `SFR_ACC` / `SFR_PSW` / `SFR_B` / `SFR_C` | 0x00-0x03 | registres CPU mappés en mémoire |
| `SFR_PCON` | 0x07 | contrôle d'alimentation (bit 0 = **HALT**) |
| `SFR_IE` | 0x08 | enable des interruptions (bit 7 = EA, le « maitre ») |
| `SFR_T0CNT` | 0x10 | contrôle Timer 0 (flags, enables, mode) |
| `SFR_T0PRR` | 0x11 | prescaler Timer 0 |
| `SFR_T0L` / `SFR_T0LR` | 0x12/0x13 | compteur low / reload low |
| `SFR_T0H` / `SFR_T0HR` | 0x14/0x15 | compteur high / reload high |
| `SFR_T1CNT` | 0x18 | contrôle Timer 1 |
| `SFR_EXT` | 0x0D | sélection de la banque d'instructions (ROM/flash) |
| `SFR_P3INT` | 0x4E | contrôle d'interruption du port 3 (boutons) |
| `SFR_BTCR` | 0x7F | contrôle du Base Timer |

### 5.4 Le pattern `loadSFR` / `storeSFR`

Les SFRs ne sont pas de simples cases mémoire : l'écriture ou la lecture peut avoir des
**effets de bord**. Deux méthodes gèrent ça :

- `loadSFR(offset)` : lecture (ex. lire T0L retourne le compteur courant, pas le reload)
- `storeSFR(offset, val)` : écriture + effets de bord (reload de timers, mise en HALT,
  changement de banque, etc.)

Par exemple, écrire dans le registre de contrôle du Timer 0 peut recharger les compteurs :

```zig
SFR_T0CNT => {
    if (val & T0CNT_T0LRUN == 0) {
        self.t0l_counter = self.sfr_raw[SFR_T0LR];  // si on arrête, on recharge T0L
    }
    if (val & T0CNT_T0HRUN == 0) {
        self.t0h_counter = self.sfr_raw[SFR_T0HR];  // idem pour T0H
    }
},
```

---

## 6. Les timers en profondeur

C'est le cœur du sujet. Il y a **trois** timers, gérés dans `timer.zig` (la logique pure)
mais dont les états/registres vivent dans le `Cpu` (`lc86K.zig`).

### 6.1 Pourquoi séparer `timer.zig` ?

Le fichier `timer.zig` contient des **fonctions libres** qui prennent `*Cpu` en argument :

```zig
pub fn tick(self: *Cpu, cycles_used: u8) void {
    tickTimer0(self, cycles_used);
    tickTimer1(self, cycles_used);
    tickBaseTimer(self, cycles_used);
}
```

Elles **mutent** le CPU (`self` est un pointeur) mais ne dépendent d'aucune fenêtre ni
de raylib. C'est le principe de la **testabilité** : on peut appeler ces fonctions dans les
tests (`tests.zig`) sans avoir besoin d'afficher quoi que ce soit.

> **Principe Zig/architecture** : on isole la logique pure (timers) dans un module sans
> dépendances externes pour pouvoir la tester unitairement. Le rendu (raylib) reste dans
> `main.zig`.

### 6.2 Les deux horloges du VMU

Deux fréquences coexistent :

| Horloge | Fréquence | Rôle |
|---------|-----------|------|
| **Horloge CPU** | 6 MHz (Dreamcast) ou variable (standalone) | cadence les instructions et Timers 0/1 |
| **Quartz RTC (fBST)** | 32 768 Hz | cadence le Base Timer |

> `fBST` = « **f**réquence **B**ase **S**ystem **T**imer ». C'est le quartz d'horlogerie de
> la RTC (une seconde en 32 768 ticks, un nombre très pratique en binaire).

#### Mode Dreamcast (connecté)

Quand la VMU est branchée sur la Dreamcast via le bus Maple, celle-ci fournit une
horloge externe de **6 MHz**. Le registre OCR n'a pas d'effet sur la fréquence CPU.

#### Mode standalone (autonome)

En mode autonome, la VMU utilise ses oscillateurs internes. Le registre OCR
(`SFR_OCR`, 0x0E) contrôle la source et le diviseur :

| OCR5:OCR4 | Source | Fréquence |
|-----------|--------|-----------|
| 00 | RC oscillator | 879 236 Hz |
| 10 | Quartz oscillator | 32 768 Hz |

| OCR7 | Diviseur | Résultat (RC) | Résultat (Quartz) |
|------|----------|---------------|-------------------|
| 0 | /12 | ~73 kHz | ~2 731 Hz |
| 1 | /6 | ~146 kHz | ~5 461 Hz |

> Après le reset hardware, le BIOS démarre en RC /12 (~73 kHz), puis bascule vers
> Quartz /6 (~5,4 kHz) pour économiser la batterie.

#### Constantes dans le code

```zig
// Fréquences des oscillateurs (lc86K.zig)
pub const RC_FREQ: u32 = 879_236;
pub const QUARTZ_FREQ: u32 = 32_768;
pub const DREAMCAST_FREQ: u32 = 6_000_000;

// Champs runtime sur Cpu (mis à jour par updateClock())
cpu_freq: u32,                    // fréquence CPU courante en Hz
fBST_per_cycle_fp: u32,           // Q16: ticks fBST par cycle CPU
dreamcast_connected: bool,        // true = Dreamcast, false = standalone
```

**Le rapport fBST/CPU est maintenant calculé en fixed-point Q16** pour gérer
les cas où le CPU est plus lent que le base timer (standalone quartz).
L'accumulateur du base timer (`base_timer_acc`) utilise ce rapport pour
convertir les cycles CPU en ticks fBST.

### 6.3 Le Timer 0 (mode 0 et mode 2)

Le Timer 0 a un **prescaler** (diviseur) et plusieurs modes. Le mode est choisi par deux
bits du registre `T0CNT` : `T0LONG` (bit 5) et `T0LEXT` (bit 4).

```zig
pub fn t0Mode(self: *Cpu) u2 {
    const t0cnt = self.sfr_raw[Cpu.SFR_T0CNT];
    return @truncate((t0cnt & (Cpu.T0CNT_T0LONG | Cpu.T0CNT_T0LEXT)) >> 4);
}
```

On extrait un nombre de 2 bits (le mode) depuis les bits 4 et 5 de `T0CNT`.

#### Le prescaler (commun)

Le prescaler est un diviseur configurable :

```zig
const prescaler_period: u16 = 256 - @as(u16, self.sfr_raw[Cpu.SFR_T0PRR]);
self.t0_prescaler_acc += cycles_used;
while (self.t0_prescaler_acc >= prescaler_period) {
    self.t0_prescaler_acc -= prescaler_period;
    switch (mode) { ... }   // on « tick » le compteur selon le mode
}
```

- Le registre `T0PRR` définit la période du prescaler `= 256 - T0PRR`.
- On accumule les cycles CPU écoulés.
- Dès que l'accumulateur atteint la période, on **décrémente la période** et on fait
  « avancer d'un pas » le compteur selon le mode actif.

#### Mode 0 — deux timers 8-bit indépendants

```zig
fn incrementT0Mode0(self: *Cpu) void {
    const t0cnt = self.sfr_raw[Cpu.SFR_T0CNT];
    if (t0cnt & Cpu.T0CNT_T0LRUN != 0) {   // T0L activé ?
        const old = self.t0l_counter;
        self.t0l_counter +%= 1;            // incrémente
        if (old == 0xFF) {                 // overflow ?
            self.t0l_counter = self.sfr_raw[Cpu.SFR_T0LR];  // reload
            self.sfr_raw[Cpu.SFR_T0CNT] |= Cpu.T0CNT_T0LOVF; // pose le flag
        }
    }
    // ... même logique pour T0H avec T0HRUN et T0HOVF
}
```

Chaque demi-timer ne tourne que si son **bit RUN** est à 1. À l'overflow, on recharge la
valeur de reload et on pose un **flag d'overflow** (qui servira pour l'interruption).

#### Mode 2 — timer 16-bit en cascade

```zig
fn incrementT0Mode2(self: *Cpu) void {
    const old_l = self.t0l_counter;
    self.t0l_counter +%= 1;
    if (old_l == 0xFF) self.t0h_counter +%= 1;   // T0L déborde → T0H++
    if (old_l == 0xFF and self.t0h_counter == 0x00) {
        // overflow COMPLET
        self.sfr_raw[Cpu.SFR_T0CNT] |= Cpu.T0CNT_T0HOVF | Cpu.T0CNT_T0LOVF;
        self.t0l_counter = self.sfr_raw[Cpu.SFR_T0LR];   // reload complet
        self.t0h_counter = self.sfr_raw[Cpu.SFR_T0HR];
    }
}
```

Ici `T0H:T0L` forme un compteur **16 bits**. Quand T0L déborde (passe de 255 à 0), on
incrémente T0H. Quand T0H déborde aussi, on a un overflow 16-bit complet : on pose **les
deux** flags et on recharge les deux compteurs.

### 6.4 Le Timer 1 (mode 0 et mode 2)

Le Timer 1 est très similaire au Timer 0 mais **sans prescaler** : il tourne à la fréquence
du cycle CPU directement. Deux modes implémentés :

- **Mode 0** (`T1LONG=0`) : deux timers 8-bit indépendants (`T1L`, `T1H`)
- **Mode 2** (`T1LONG=1`) : timer 16-bit en cascade (T1L déborde → T1H)

```zig
pub fn tickTimer1(self: *Cpu, cycles_used: u8) void {
    const t1cnt = self.sfr_raw[Cpu.SFR_T1CNT];
    var i: u8 = 0;
    while (i < cycles_used) : (i += 1) {
        if (t1cnt & Cpu.T1CNT_T1LONG != 0) incrementT1Mode2(self)
        else                                  incrementT1Mode0(self);
    }
}
```

> Remarque : le Timer 1 fait **un tick par cycle** (boucle `while` sur `cycles_used`),
> contrairement au Timer 0 qui accumule dans un prescaler. C'est la différence de conception
> entre les deux timers du vrai matériel.

### 6.5 Le Base Timer (RTC) — le plus important

Le Base Timer fait tourner la « montre » du VMU à 32 768 Hz. C'est lui qui génère les
interruptions périodiques (`INT3`) qui font vivre le BIOS.

```zig
pub fn tickBaseTimer(self: *Cpu, cycles_used: u8) void {
    const btcr = self.sfr_raw[Cpu.SFR_BTCR];
    if (btcr & Cpu.BTCR_BT_RUN == 0) return;   // arrêté → rien

    self.base_timer_acc += cycles_used;
    while (self.base_timer_acc >= Cpu.CYCLES_PER_FBST_TICK) {
        self.base_timer_acc -= Cpu.CYCLES_PER_FBST_TICK;
        const old_counter = self.base_timer_counter;
        self.base_timer_counter = (self.base_timer_counter + 1) & 0x3FFF; // 14 bits
        const new_counter = self.base_timer_counter;

        // BT0 : overflow selon BTCR7
        const int0_rate: u16 = if (btcr & Cpu.BTCR_BT0_CYCLE != 0) 0x0040 else 0x4000;
        if (old_counter / int0_rate < new_counter / int0_rate or new_counter == 0) {
            self.sfr_raw[Cpu.SFR_BTCR] |= Cpu.BTCR_BT0_FLAG;
        }

        // BT1 : seuil configurable selon BTCR5:BTCR4
        const bt1_idx: u2 = @truncate((btcr & (Cpu.BTCR_BT1_CYCLE_HI | Cpu.BTCR_BT1_CYCLE_LO)) >> 4);
        if (new_counter == Cpu.BT1_THRESHOLDS[bt1_idx]) {
            self.sfr_raw[Cpu.SFR_BTCR] |= Cpu.BTCR_BT1_FLAG;
        }
    }
}
```

Décortiquons :

1. **Arrêt** : si le bit de lancement `BTCR_BT_RUN` (bit 6) vaut 0, le timer ne tourne pas.
2. **Accumulation** : on ajoute les cycles CPU écoulés. Chaque fois qu'on atteint 183
   (un tick fBST), on entre dans la boucle.
3. **Compteur 14-bit** : `& 0x3FFF` force le compteur à rester sur 14 bits (0 à 16383),
   le masquage binaire simulé par opération (`&` = AND bit à bit).
4. **BT0** : pose un flag à un **intervalle** donné — 16384 ticks (≈0.5 s) ou 64 ticks
   (≈2 ms, « fast-forward ») selon le bit `BTCR7`. La division d'intervalles détecte le
   franchissement d'une borne.
5. **BT1** : pose un flag quand le compteur atteint **exactement** un seuil choisi parmi
   {32, 128, 512, 2048} ticks selon les bits `BTCR5:BTCR4`.

Les deux flags (`BT0_FLAG`, `BT1_FLAG`) peuvent chacun déclencher l'interruption `INT3`.

> **Comprendre le comptage « en cycles CPU »** : le CPU ne « sait » pas qu'il y a un quartz
> à 32 768 Hz. Tout est cadencé par les cycles CPU. Grâce au rapport 183 cycles = 1 fBST tick,
> on convertit les cycles CPU écoulés en ticks de quartz. C'est le rôle de
> `CYCLES_PER_FBST_TICK`.

### 6.6 Résumé visuel des timers

```
Horloge CPU (~6 MHz)
   │
   ├──► TIMER 0 : prescaler (256 - T0PRR) → mode 0 (2×8bit) ou mode 2 (16bit)
   │         → flags T0LOVF (INT2), T0HOVF (T0H)
   │
   ├──► TIMER 1 : pas de prescaler, 1 tick/cycle → mode 0 (2×8bit) ou mode 2 (16bit)
   │         → flags T1LOVF, T1HOVF (INT T1)
   │
   └──► BASE TIMER : accumulation, 183 cycles = 1 tick fBST
             → compteur 14-bit à 32 768 Hz
             → flags BT0_FLAG / BT1_FLAG (INT3, la RTC)
```

---

## 7. Les interruptions en profondeur

### 7.1 Le principe d'une interruption

Une interruption (IRQ) permet à un **périphérique** (timer, bouton) d'« interrompre » le
CPU pour qu'il exécute un code de traitement, puis reprenne là où il en était.

Le déroulement :

1. Le matériel pose un **flag source** (ex. le timer a débordé).
2. Si ce flag est **autorisé** (enable) et que le **master enable** (EA) est actif, le CPU :
   - **sauvegarde** l'adresse de retour sur la pile,
   - **saute** à une adresse fixe appelée **vecteur**,
   - **efface** le flag source (sinon l'IRQ se redéclenche à l'infini).
3. Le code de traitement se termine par **`RETI`** qui restaure le PC.

### 7.2 Les sources d'interruption du projet

| IRQ | Vecteur | Source |
|-----|---------|--------|
| `INT2` | `0x0013` | Timer 0 **low** overflow |
| `INT3` | `0x001B` | Base Timer (BT0 **ou** BT1 flag) |
| `T0H` | `0x0023` | Timer 0 **high** overflow |
| `T1` | `0x002B` | Timer 1 (T1H ou T1L overflow) |
| `P3` | `0x004B` | Port 3 (boutons) |

Ces vecteurs et la logique sont dans `lc86K.zig`, dans l'enum `Cpu.Interruptions` et la
fonction `servicePendingInterrupt()`.

### 7.3 Les garde-fous avant de servir une IRQ

```zig
pub fn servicePendingInterrupt(self: *Cpu) void {
    var val: ?Interruptions = null;

    if (self.interrupt_depth != 0) return;   // déjà dans une IRQ → pas de nesting

    // skip pendant 1 instruction après RETI (sémantique libevmu)
    if (!self.process_this_instr) {
        self.process_this_instr = true;
        return;
    }

    if (self.interrupt_blocked > 0) {
        self.interrupt_blocked -%= 1;
        return;
    }

    const ie = self.sfr_raw[SFR_IE];
    if (ie & 0x80 == 0) return;   // EA (master enable) off → rien
    ...
}
```

Cinq conditions avant de pouvoir servir une IRQ :

1. **`interrupt_depth == 0`** : on n'est pas déjà en train de servir une IRQ (pas de nesting).
2. **`process_this_instr`** : on saute l'émission d'IRQ pendant 1 instruction après `RETI`
   (une règle de timing du vrai matériel).
3. **`interrupt_blocked == 0`** : on ne sert pas d'IRQ juste après avoir modifié IE/IP
   (laisse le temps à la configuration de se stabiliser).
4. **`EA == 1`** (bit 7 de IE) : le master enable global.
5. **flag source + enable local** : le périphérique doit poser son flag **et** être autorisé.

### 7.4 La sélection de la priorité

La fonction utilise une série de `if`/`else` qui évalue les sources par **priorité
décroissante** — la première trouvée gagne :

```zig
if (t0cnt & T0CNT_T0LOVF != 0 and t0cnt & T0CNT_T0LIE != 0) {
    val = .int2;                        // 1er : INT2 (T0L)
} else if ((btcr & BTCR_BT0_FLAG != 0 and btcr & BTCR_BT0_IE != 0) or
           (btcr & BTCR_BT1_FLAG != 0 and btcr & BTCR_BT1_IE != 0)) {
    val = .int3;                        // 2e : Base Timer
} else if (t0cnt & T0CNT_T0HOVF != 0 and t0cnt & T0CNT_T0HIE != 0) {
    val = .t0h;                         // 3e : T0H
} else { ... t1 ... }
```

Puis, si toujours rien, on regarde P3 (boutons) et la Maple IRQ :

```zig
if (val == null) {
    const p3int = self.sfr_raw[SFR_P3INT];
    if (p3int & P3INT_P30INT != 0 and p3int & P3INT_P31INT != 0) {
        val = .p3;
    }
}
if (val == null and self.maple_irq_pending) {
    val = .maple;
}
```

> `val` est de type `?Interruptions`, une **option** (« nullable ») : `null` tant qu'aucune
> source n'est trouvée. C'est le typage Zig qui rend l'absence de valeur explicite.

### 7.5 Servir l'interruption

```zig
const vecteur: u16 = if (val) |irq| switch (irq) {
    .int2 => 0x0013,
    .int3 => 0x001B,
    .t0h  => 0x0023,
    .t1   => 0x002B,
    .maple => 0x0043,
    .p3   => 0x004B,
} else return;

// Sauvegarde du PC sur la pile (2 octets)
const return_addr = self.pc;
self.sp +%= 1;
self.ram_bank0[self.sp] = @truncate(return_addr & 0xFF);   // octet bas
self.sp +%= 1;
self.ram_bank0[self.sp] = @truncate(return_addr >> 8);     // octet haut

self.pc = vecteur;        // saut au gestionnaire
self.interrupt_depth = 1; // bloque le nesting
self.halted = false;      // réveille le CPU si en HALT
```

Puis, crucial, on **efface le flag source** afin que l'IRQ ne se redéclenche pas :

```zig
if (val) |irq| switch (irq) {
    .int2 => self.sfr_raw[SFR_T0CNT] &= ~T0CNT_T0LOVF,
    .int3 => self.sfr_raw[SFR_BTCR] &= ~(BTCR_BT0_FLAG | BTCR_BT1_FLAG),
    .t0h  => self.sfr_raw[SFR_T0CNT] &= ~T0CNT_T0HOVF,
    .t1   => self.sfr_raw[SFR_T1CNT] &= ~(T1CNT_T1HOVF | T1CNT_T1LOVF),
    .p3   => self.sfr_raw[SFR_P3INT] &= ~P3INT_P31INT,
    .maple => self.maple_irq_pending = false,
};
```

> **Point délicat pour INT3** : BT0 et BT1 partagent le même vecteur. On efface **les deux**
> flags. Le code du BIOS (ou du jeu) détermine lui-même laquelle des deux sources a déclenché
> en lisant les flags.

### 7.6 RETI — retour d'interruption

Quand le gestionnaire a fini, il exécute `RETI` (dans `decode.zig`) :

```zig
.reti => {
    const hi = cpu.ram_bank0[cpu.sp];   // lit l'octet haut
    cpu.sp -%= 1;
    const lo = cpu.ram_bank0[cpu.sp];   // lit l'octet bas
    cpu.sp -%= 1;
    cpu.pc = (@as(u16, hi) << 8) | @as(u16, lo);   // restaure PC
    cpu.interrupt_depth = 0;            // re-autorise les IRQ
    cpu.process_this_instr = false;     // saute la prochaine émission d'IRQ
},
```

La pile avait stocké l'adresse de retour à l'envers (bas puis haut) ; `RETI` la relit à
l'envers (haut puis bas) pour retrouver le bon PC.

### 7.7 Le HALT et le réveil par interruption

Le CPU peut être mis en **veille** (`HALT`) en posant le bit 0 de `PCON`. En HALT, il
n'exécute plus d'instruction mais les timers continuent de tourner.

Dans `step()` (`decode.zig`), le début gère cet état :

```zig
if (cpu.halted) {
    const old_p3 = cpu.p3_buttons;
    cpu.tickTimers(1);
    cpu.requestLevelDrivenInterrupts();
    cpu.servicePendingInterrupt();
    if (cpu.halted and cpu.p3_buttons != old_p3) {
        cpu.halted = false;   // un appui bouton réveille même sans IRQ
    }
    return 1;
}
```

Deux façons de sortir du HALT :

1. **Une interruption** est servie → `servicePendingInterrupt()` met `halted = false`.
2. **Un changement de bouton** sur P3 → réveil direct (comportement matériel).

Dans `main.zig`, pendant qu'on est en HALT, on fait tourner les timers sur toute la durée
restante de l'image pour que l'interruption RTC puisse se déclencher :

```zig
if (cpu.halted) {
    const remaining: u32 = @intCast(cycles_per_frame - i);
    var ticked: u32 = 0;
    while (ticked < remaining) {
        const batch: u8 = @intCast(@min(remaining - ticked, 255));
        cpu.tickTimers(batch);
        tagged += batch;
        cpu.requestLevelDrivenInterrupts();
        cpu.servicePendingInterrupt();
        if (!cpu.halted) break;   // on s'est réveillé → on arrête
    }
    ...
}
```

> **Pourquoi ?** Sur la vraie VMU, le quartz RTC continue de tourner même quand le CPU dort.
> Sans cette boucle, l'interruption périodique ne pourrait jamais se déclencher pendant un
> HALT, et le CPU resterait endormi pour toujours. On « avance » simplement les timers jusqu'à
> la fin de l'image pour laisser le temps à l'IRQ de venir réveiller le CPU.

### 7.8 Le blocage après écriture de IE/IP

```zig
SFR_IE, SFR_IP => {
    self.interrupt_blocked = 1;
},
```

Quand l'application modifie la configuration des interruptions (IE ou IP), on pose un
« blocage » d'un cycle (`interrupt_blocked = 1`). Au cycle suivant, `servicePendingInterrupt()`
ne fait rien et décrémente ce compteur. Cela évite de servir une IRQ avec une configuration
pas encore stabilisée.

---

## 8. Le système de fichiers flash VMU/FAT

Cette partie est dans `vmu.zig`. Elle est passionnante car elle crée **un vrai système de
fichiers** au format VMU, identique à celui d'une carte mémoire réelle.

### 8.1 La topologie de la flash

La flash fait **128 Ko** = `256 blocs` de **512 octets** chacun (offset = `n°bloc × 512`).

| Blocs | Rôle |
|-------|------|
| `0` – `199` | Données utilisateur (les jeux/sauvegardes) |
| `200` – `240` | Zone **cachée** |
| `241` – `253` | **Répertoire** (les entrées de fichiers) |
| `254` | **FAT** (File Allocation Table) — la « table des blocs » |
| `255` | **Root** (bloc racine, l'en-tête du volume) |

> C'est exactement la structure d'un volume VMS Dreamcast. Le jeu est stocké dans les blocs
> de données, et la FAT dit « quels blocs appartiennent à ce fichier et dans quel ordre ».

### 8.2 Le bloc racine (Root, bloc 255)

`initVmuFlash()` écrit d'abord partout `0xFF` (état d'une flash **effacée**), puis remplit
le bloc racine. Le root est l'en-tête qui décrit tout le volume :

```zig
const rb: usize = 255 * 512;
for (0..16) |i| flash[rb + i] = 0x55;   // magic 0x55
flash[rb + 0x40] = 0xFF;                 // VolumeLast
flash[rb + 0x44] = 0xFF; flash[rb + 0x45] = 0x00;  // Root
flash[rb + 0x46] = 0xFE; flash[rb + 0x47] = 0x00;  // FATFirst
flash[rb + 0x4A] = 0xFD; flash[rb + 0x4B] = 0x00;  // DirLast
flash[rb + 0x4C] = 0x0D; flash[rb + 0x4D] = 0x00;  // DirSize
...
flash[rb + 0x54] = 0x00; flash[rb + 0x55] = 0x00;  // GameFirst
flash[rb + 0x56] = 0x80;                           // GameSize = 128 blocs
```

Points pédagogiques :

- **`magic 0x55`** : les 16 premiers octets sont une signature qui dit « c'est un volume VMU ».
- **Offsets** : chaque champ a son offset fixe dans le bloc (documenté dans le manuel VMU).
- **Little-endian** : les quantités sur 2 octets sont stockées **octet bas d'abord**
  (`0x00FE` devient `0xFE 0x00`). C'est pour ça qu'on voit `flash[...] = 0xFE; flash[...+1] = 0x00;`.
- **`GameFirst`/`GameSize`** : ici le « plus grand » fichier (le jeu) commence au bloc 0 et
  fait 128 blocs (128 × 512 = 64 Ko, sois la taille du jeu chargé).

### 8.3 La FAT (bloc 254)

La **File Allocation Table** est un tableau de pointeurs : l'**entrée `n`** dit vers quel bloc
pointe le bloc `n` (le bloc suivant dans un fichier). Chaque entrée fait **2 octets** (16 bits).

```zig
const fb: usize = 254 * 512;
// Le bloc 255 (root) marque la fin d'un fichier
flash[fb + 255 * 2] = 0xFA;   flash[fb + 255 * 2 + 1] = 0xFF;
// Le bloc 254 (la FAT elle-même) marque aussi une fin
flash[fb + 254 * 2] = 0xFA;   flash[fb + 254 * 2 + 1] = 0xFF;
// La chaîne du répertoire : 253 → 252 → ... → 241 → Fin
{
    var i: u16 = 253;
    while (i > 241) : (i -= 1) {
        flash[fb + i * 2] = @intCast(i - 1);
        flash[fb + i * 2 + 1] = 0x00;
    }
    flash[fb + 241 * 2] = 0xFA;   flash[fb + 241 * 2 + 1] = 0xFF;
}
```

- L'**adresse de l'entrée `i`** est `fb + i * 2` (chaque entrée = 2 octets).
- La valeur **`0xFFFA`** est le marqueur spécial **`FAT_LastInFile`** : « ce bloc est le
  dernier de son fichier ».
- Ici, on relie les blocs du répertoire entre eux en une **chaîne** : le bloc 253 contient
  un pointeur vers 252, celui-là vers 251, … 241 pointe vers `FAT_LastInFile`.

> **Lire la FAT** : `FAT[i] = j` signifie « le prochain bloc après `i` est `j` ». Pour suivre
> un fichier : on part du bloc de départ, puis `FAT[bloc]`, puis `FAT[FAT[bloc]]`… jusqu'à
> tomber sur `FAT_LastInFile`.

### 8.4 Le répertoire — l'entrée du jeu

Le fichier `installGame()` crée l'entrée de répertoire du jeu dans le **bloc 253** (le premier
bloc du répertoire) :

```zig
const dir_base = 253 * 512;
flash[dir_base + 0x00] = 0xCC;  // FileType = Game
flash[dir_base + 0x01] = 0x80;  // CopyProtection = libre
flash[dir_base + 0x02] = 0x00;  // StartFAT low
flash[dir_base + 0x03] = 0x00;  // StartFAT high  → le jeu commence au bloc 0 !!
// Filename : 12 octets à partir de l'offset 0x04
const game_name = "GAME";
for (game_name, 0..) |ch, idx| {
    flash[dir_base + 0x04 + idx] = ch;
}
// Taille en blocs à l'offset 0x18
const size_blocks: u16 = @intCast((game_size + 511) / 512);
flash[dir_base + 0x18] = @truncate(size_blocks);
flash[dir_base + 0x19] = @truncate(size_blocks >> 8);
// L'en-tête VMS se trouve au bloc 1 (offset 0x1A)
flash[dir_base + 0x1A] = 0x01;  flash[dir_base + 0x1B] = 0x00;
```

**Les champs d'une entrée de répertoire VMU :**

| Offset | Champ | Ici |
|--------|-------|-----|
| `0x00` | `FileType` | `0xCC` = « Game » |
| `0x01` | `CopyProtection` | `0x80` = copie autorisée |
| `0x02`-`0x03` | `StartFAT` = **premier bloc** du fichier | `0x0000` = bloc 0 |
| `0x04`-`0x0F` | `Filename` (12 octets) | `"GAME"` |
| `0x18`-`0x19` | `SizeInBlocks` | nombre de blocs du jeu |
| `0x1A`-`0x1B` | `VmsHeaderBlockOffset` | bloc 1 (le header VMS) |

> Explication du calcul de taille :
> `size_blocks = (game_size + 511) / 512` arrondit **au nombre supérieur** de blocs de 512
> octets. Si le jeu fait 1000 octets → `(1000 + 511)/512 = 1511/512 = 2` blocs. Le `+511`
> garantit l'arrondi par excès.

### 8.5 La chaîne FAT du jeu

Enfin, on chaîne tous les blocs du jeu entre eux dans la FAT :

```zig
const fat_base: usize = 254 * 512;
const last_game_block: u16 = @intCast((game_size + 511) / 512 - 1);
var b: u16 = 0;
while (b <= last_game_block) : (b += 1) {
    const fat_off: usize = fat_base + @as(usize, b) * 2;
    if (b == last_game_block) {
        flash[fat_off] = 0xFA;      // dernier bloc → FAT_LastInFile
        flash[fat_off + 1] = 0xFF;
    } else {
        flash[fat_off] = @truncate(b + 1);   // bloc b pointe vers b+1
        flash[fat_off + 1] = 0x00;
    }
}
```

Résultat : bloc 0 → 1 → 2 → … → dernier → `FAT_LastInFile`. Le bios peut lire le jeu en
suivant cette chaîne.

### 8.6 Vue d'ensemble du « volume » créé

```
Bloc 255 (Root)     : magic 0x55, dit où sont la FAT, le répertoire et le jeu
Bloc 254 (FAT)      : chaîne du répertoire (253→…→241) + chaîne du jeu (0→1→2→…)
Blocs 241-253 (Dir) : entrée du jeu dans le bloc 253 → StartFAT=bloc 0
Blocs 0..N (Jeu)    : le programme chargé, enchaîné par la FAT
```

Quand le BIOS « explore » la carte, il lit le root, trouve `GameFirst`/`GameSize`, lit
l'entrée du répertoire, suit la FAT depuis le bloc de départ — et récupère le jeu. C'est
exactement le comportement d'une vraie VMU.

### 8.7 `initBiosRtc` — préparer le BIOS

C'est dans `vmu.zig` aussi. On écrit la **date courante** en RAM (au format BCD et binaire)
et on règle les SFRs comme le ferait le vrai matériel au boot :

```zig
cpu.pc = 0x2E1;                       // saute le query date série
cpu.ram_bank0[0x10] = 0x20;           // Century BCD (20)
cpu.ram_bank0[0x11] = 0x26;           // Year BCD (26)
cpu.ram_bank0[0x12] = 0x07;           // Month BCD (07)
...
cpu.sfr_raw[Cpu.SFR_IE] = 0xFF;       // toutes les IRQ activées
cpu.sfr_raw[Cpu.SFR_BTCR] = 0x41;     // base timer en marche
```

> **BCD** = chaque chiffre décimal occupe un demi-octet (nibble). `0x26` signifie « 2, 6 » =
> l'année 26. C'est le format utilisé par les horloges temps réel.

---

## 9. Le BIOS : son rôle, ses phases et le lancement du jeu

C'est une particularité de ce projet : on charge un **vrai BIOS VMU** et on le laisse
s'exécuter. Le code du BIOS (dans la ROM) fait lui-même l'initialisation, affiche son menu,
trouve le jeu et le lance — comme sur une vraie machine. L'émulateur ne « simule » pas le
menu, il **exécute réellement** le BIOS.

### 9.1 Où vit le BIOS ? ROM vs Flash

Le CPU a une **banque d'instructions** de 64 Ko (`inst_bank`) qui peut pointer vers trois
espaces distincts :

```zig
inst_bank: struct {
    data: []u8,
    bank_id: enum { rom, flash0, flash1 },
},
```

- **`rom`** : le BIOS (chargé dans 64 Ko de ROM)
- **`flash0`** : les 64 premiers Ko de la flash (le jeu)
- **`flash1`** : les 64 derniers Ko de la flash

Le CPU exécute les instructions depuis la banque courante. Au boot, on est en **ROM**
(le BIOS). Quand le lancement du jeu est décidé, on **bascule** vers `flash0`.

### 9.2 La bascule de banque — `EXT` et `pending_ext`

Le registre `EXT` (0x0D) contrôle le choix de la banque. Mais le changement est **différé** :
on écrit d'abord la valeur dans `pending_ext`, puis on l'« applique » au moment voulu.

```zig
SFR_EXT => {
    self.ext_write_pc = self.pc;
    self.pending_ext = val;   // on mémorise, on ne bascule pas encore
},
```

Puis la bascule effective se fait par `syncInstructionBank()` :

```zig
pub fn syncInstructionBank(self: *Cpu) void {
    const ext = self.pending_ext;
    if (ext & 0x08 != 0) {            // bit 3 = « aller en flash »
        self.inst_bank.data = self.flash[0..65536];
        self.inst_bank.bank_id = .flash0;
    } else {
        self.inst_bank.data = self.rom_data;
        self.inst_bank.bank_id = .rom;
    }
}
```

> **Particularité matérielle documentée** (voir les commentaires du code) : sur le VMU, ce
> n'est pas le bit 0 d'`EXT` qui choisit la banque, mais le **bit 3** (0x08). Le BIOS historique
> de lancement écrit notamment **0x88** pour passer en flash et **0x80** pour rester en ROM.
> `0x80` est un indicateur de « mode système », le bit de commutation utile est 0x08.

Dans `decode.zig`, `syncInstructionBank()` est appelé juste après l'instruction `JMPF` (saut
absolu), au moment où on saute réellement vers la nouvelle banque :

```zig
.jmpf => {
    const hi = cpu.fetch8();
    const lo = cpu.fetch8();
    cpu.pc = (@as(u16, hi) << 8) | @as(u16, lo);
    cpu.syncInstructionBank();  // la bascule est commitée ici
},
```

### 9.3 Le suivi des phases du BIOS

Le projet définit un **enum `BiosPhase`** qui décrit où en est le BIOS dans son déroulement :

```zig
pub const BiosPhase = enum(u8) {
    none,
    bios_init,
    bios_clear_ram,
    bios_post_init,
    bios_date_wait,
    bios_lcd_setup,
    bios_date_ok,
    bios_main_loop,
    bios_mode_0,
    bios_mode_1,
    bios_mode_2,
    bios_game_launch,
    bios_no_game,
    game_running,
};
```

Comment sait-on quelle phase on atteint ? Le BIOS est un code à adresses **fixes** (c'est de
la ROM désassemblée). La fonction `checkBiosPhase()` (`debug.zig`) associe des **valeurs de PC
à des phases** :

```zig
const new_phase: ?Cpu.BiosPhase = switch (cpu.pc) {
    0x0200 => .bios_init,
    0x024C => .bios_clear_ram,
    0x0294 => .bios_post_init,
    0x02AF => .bios_date_wait,
    0x02C2 => .bios_lcd_setup,
    0x02EF => .bios_date_ok,
    0x0317 => .bios_main_loop,
    0x033A => .bios_mode_0,
    0x0360 => .bios_mode_1,
    0x0387 => .bios_mode_2,
    0x03AE => .bios_game_launch,
    0x03E1 => .bios_no_game,
    else => null,
};
```

> **Astuce d'émulateur** : au lieu de désassembler et instrumenter le code du BIOS, on
> « mappe » des adresses PC connues vers des phases logiques. En observant le PC courant du
> CPU, on sait dans quelle étape du boot on se trouve.

Cette fonction est appelée à chaque `step()` depuis `main.zig` :

```zig
_ = step(&cpu);
_ = dbg.checkBiosPhase(&cpu);   // met à jour cpu.bios_phase
```

Elle ne renvoie la phase que **la première fois** qu'elle est observée (grâce au tableau
`bios_phase_seen`), pour éviter les logs répétés.

Quand le CPU sort de la ROM (il est passé en `flash0`), la phase devient uniformément
`game_running` :

```zig
if (cpu.inst_bank.bank_id != .rom) {
    if (cpu.bios_phase != .game_running) {
        cpu.bios_phase = .game_running;
        return .game_running;
    }
    return null;
}
```

### 9.4 Le déroulement typique du boot

En suivant les phases, voici le cheminement de la mise sous tension jusqu'au jeu :

```
PC=0x0200 bios_init           → démarrage, initialisation de base
PC=0x024C bios_clear_ram      → efface la RAM
PC=0x0294 bios_post_init      → suite de l'initialisation
PC=0x02AF bios_date_wait      → attend/valide la date (RTC)
PC=0x02C2 bios_lcd_setup      → configure l'affichage LCD
PC=0x02EF bios_date_ok        → date confirmée
PC=0x0317 bios_main_loop      → menu principal (boucle d'attente)
PC=0x033A/0x360/0x387          → modes du menu (navigation)
PC=0x03AE bios_game_launch    → décision de lancer le jeu
   │
   └── (transition vers flash0, voir 9.5)
```

### 9.5 La transition BIOS → jeu

Si le BIOS a une carte (avec un jeu installé), il passe par la phase `bios_game_launch`.
Dans `main.zig`, on intercepte cette phase pour finaliser « proprement » la bascule vers le
jeu :

```zig
if (!bios_menu_selected and cpu.bios_phase == .bios_game_launch) {
    // Clear P3 latch before game starts
    cpu.p3_buttons = 0xFF;
    cpu.prev_p3_buttons = 0xFF;
    cpu.ram_bank0[0x70] = 0xFF;
    cpu.sfr_raw[Cpu.SFR_P3INT] = 0xFD;
    cpu.setInstructionBank(.flash0);   // bascule vers la banque flash0 (le jeu)
    cpu.pc = 0x0000;                   // et on démarre au début du jeu
    bios_menu_selected = true;
    bios_menu_active = false;
    start_pulse_frames = 0;
}
```

Ce bloc fait exactement ce que ferait le matériel au moment du passage du contrôle :

1. **Réinitialise l'état des boutons** (`P3 = 0xFF`) pour qu'aucun appui « collé » du BIOS
   (MODE, Start) ne fuite dans le jeu en flash0.
2. **Bascule la banque d'instructions** vers `flash0` (le jeu) via `setInstructionBank()`.
3. **Repart le PC à 0x0000** — l'adresse d'entrée du jeu.
4. Marque la transition faite (`bios_menu_selected = true`) pour ne la faire qu'une fois.

> `setInstructionBank(.flash0)` est l'équivalent « direct » de la bascule différée :
> contrairement à `syncInstructionBank()` qui lit `pending_ext`, cette méthode **force**
> immédiatement la banque voulue. Elle est utilisée ici pour la transition contrôlée depuis
> la boucle principale.

### 9.6 Le menu du BIOS émulé

Quand on lance en mode `--bios-menu` (ou avec deux fichiers), l'émulateur affiche un **menu
de lancement simplifié** à l'écran jusqu'à ce que l'utilisateur confirme avec le bouton MODE :

```zig
fn drawBiosMenuScreen(game_path: []const u8) void {
    rl.clearBackground(rl.Color.black);
    rl.drawRectangle(0, 0, LCD_W * SCALE, LCD_H * SCALE, rl.Color.black);
    rl.drawText("SEGA", 8, 4, 14, rl.Color.white);
    rl.drawText("Visual Memory", 8, 20, 10, rl.Color.white);
    // ... nom du jeu, "MODE to launch" ...
}
```

> C'est une simplification de l'interface : on n'émule pas le menu graphique complet du BIOS,
> on affiche un sélecteur minimal et on attend l'appui sur MODE (touche `M`). En revanche, le
> **code du BIOS réel tourne toujours** en arrière-plan — le menu émulé ne fait que choisir
> « vers quelle banque basculer » au moment opportun.

### 9.7 Pourquoi tant de « petites » logiques autour du BIOS ?

Le BIOS réel est exigeant : il vérifie les états des registres, attend des interruptions
périodiques RTC, surveille l'état des boutons via P3INT… L'émulateur doit **miner ces
attentes** avec un timing assez fidèle pour que le BIOS progresse naturellement. C'est
pour cela que le projet accorde tant de soin aux timers (pour produire `INT3` à fréquence
RTC) et à la logique P3 (pour générer les bonnes interruptions de boutons). Sans cette
fidélité, le BIOS bouclerait à l'infini sans jamais arriver à `bios_game_launch`.

---

## 10. Les boutons P3 et le rendu LCD

### 10.1 Le port P3 (boutons)

Le port P3 est l'interface en lecture des boutons, **active-low** : un bit à `0` signifie
« bouton appuyé », un bit à `1` « relâché ». `0xFF` = aucun bouton pressé.

Voir `updateButtons()` dans `main.zig` :

```zig
var buttons: u8 = 0xFF;
if (rl.isKeyDown(.up) or rl.isKeyDown(.w)) buttons &= ~@as(u8, 0x01); // Up
if (rl.isKeyDown(.down) or rl.isKeyDown(.s)) buttons &= ~@as(u8, 0x02); // Down
if (rl.isKeyDown(.left) or rl.isKeyDown(.a)) buttons &= ~@as(u8, 0x04); // Left
if (rl.isKeyDown(.right) or rl.isKeyDown(.d)) buttons &= ~@as(u8, 0x08); // Right
if (rl.isKeyDown(.z) or rl.isKeyDown(.k)) buttons &= ~@as(u8, 0x10); // A
if (rl.isKeyDown(.x) or rl.isKeyDown(.l)) buttons &= ~@as(u8, 0x20); // B
```

- On part de `0xFF` (tout relâché).
- `buttons &= ~0x01` met le bit 0 à 0 quand on appuie sur Up. `~` est le **complément à un**
  (inversion des bits), et `&=` est un AND bit à bit. C'est le pattern pour « éteindre un bit ».
- Il y a deux layouts clavier (`--azerty` ou standard), d'où la double condition.

Cet état est stocké dans `cpu.p3_buttons`, puis écrit à l'adresse de lecture du port
(`ram_bank0[0x70]`) et utilisé pour la génération de l'**interruption P3** (voir le §7).

La logique P3INT dans `updateButtons()` gère quand poser/clair le flag `P31INT` en fonction de
l'appui sur MODE, en veillant à ne pas « coller » un flag périmé qui ferait boucler le BIOS.

### 10.2 Le rendu LCD (XRAM → pixels)

L'écran fait **48×32** pixels. La XRAM contient les octets de l'image :

- banque 0 : lignes 0-15
- banque 1 : lignes 16-31
- banque 2 : les 6 octets d'icônes (bandeau sous l'écran)

Chaque **octet** de la XRAM code **8 pixels horizontaux** (un bit = un pixel). Pour une
ligne de 48 pixels il faut `48/8 = 6` octets.

```zig
fn getXramByte(cpu: *Cpu, row: u32, byte_col: u32) u8 {
    const xram_row = row / 2;
    const row_in_pair = row % 2;
    const offset = xram_row * 16 + row_in_pair * 6 + byte_col;
    if (offset < 128) return cpu.xram_banks.bank0[offset];
    if (offset < 256) return cpu.xram_banks.bank1[offset - 128];
    return 0;
}
```

**Pourquoi ce calcul `row/2` et `row%2` ?** Le VMU imbrique les lignes sur 16 octets par rangée
de la XRAM (un rendu matériel spécifique). L'émulateur reproduit ce décalage pour que l'image
soit correcte.

Dans `renderLcd()`, on déroule chaque bit de l'octet et on dessine un rectangle pour chaque
pixel allumé :

```zig
const byte = getXramByte(cpu, y, x_byte);
var bit: u3 = 7;
while (true) : (bit -%= 1) {
    if (byte & (@as(u8, 1) << @intCast(bit)) != 0) {
        const px: i32 = @intCast(x_byte * 8 + (7 - @as(u32, bit)));
        const py: i32 = @intCast(y);
        rl.drawRectangle(px * SCALE, py * SCALE, SCALE, SCALE, FG);
    }
    if (bit == 0) break;
}
```

- `bit` va de 7 à 0 (MSB vers LSB).
- `byte & (1 << bit)` teste le bit `bit` (AND bit à bit). Si non nul → le pixel est allumé.
- `x_byte * 8 + (7 - bit)` reconvertit l'indice de bit en coordonnée X (le bit 7 est le plus
  à gauche).
- `SCALE = 10` agrandit chaque pixel en un carré de 10×10 pixels d'écran pour être visible.

> **Zig** : `bit: u3` force le compteur de bits à tenir sur 3 bits (0-7). `@intCast(bit)`
> convertit ce petit nombre pour pouvoir décaler un `u8`. Le `(SCALE)` multiplicateur anime
> le rendu : l'émulateur simule un écran minuscule agrandi.

---

## 11. La boucle d'émulation pas à pas

Récapitulons le cycle complet d'une instruction avec `decode.step()` (`decode.zig`) :

```zig
pub fn step(cpu: *Cpu) u8 {
    if (cpu.halted) { ... timers + IRQ + réveil ... return 1; }

    const pc_before = cpu.pc;
    const opcode = cpu.fetch8();            // 1. lit l'octet à PC, PC++
    const dec = decodeOpcode(opcode);       // 2. cherche dans la table ISA

    switch (dec.inst) { ... }               // 3. exécute l'instruction

    const used = cycles(dec);               // 4. cycles nécessaires
    cpu.tickTimers(used);                   // 5. fait avancer les TIMERS
    cpu.requestLevelDrivenInterrupts();     // 6. vérifie P3 (boutons)
    cpu.servicePendingInterrupt();          // 7. sert une IRQ si nécessaire
    return used;
}
```

### Le rôle d'`isa.zig`

`decode.zig` ne code pas « à la main » le comportement de chaque opcode dans un gros bloc.
Il s'appuie sur la **table ISA** (`isa.zig`) qui est la référence de l'encodage des 256
opcodes. Chaque entrée contient : l'instruction, le mode d'adressage, la taille en octets,
le nombre de cycles, le mnémonique et la forme d'affichage.

```zig
const e: IsaEntry = .{ .inst = .add_imm, .mode = .imm, .size = 2, .cycles = 1,
                        .mnemonic = "ADD", .disp = .fmtImm };
```

C'est une **source unique de vérité** utilisée à la fois par :
- `decode.zig` (l'exécution),
- `debug.zig` (le désassembleur).

Ainsi, encoder une instruction correctement dans la table la corrige partout.

### Ordre d'appel récapitulatif

```
image (1/60 s)
 ├─ updateButtons()                     clavier → P3
 └─ 100 000 × step()
      ├─ fetch opcode
      ├─ exécuter l'instruction
      ├─ tickTimers(cycles)             TIMERS avancent
      ├─ requestLevelDrivenInterrupts() P3
      └─ servicePendingInterrupt()      IRQ éventuelle
 └─ renderLcd()                         XRAM → pixels à l'écran
```

C'est cette **boucle** qui fait coexister « exécuter du code », « faire avancer le temps »
(timers) et « réagir aux événements » (interruptions, boutons).

---

## 12. Les tests

Le projet contient 92 tests dans `tests.zig`. Ils valident le comportement des instructions
par rapport aux exemples du manuel VMC (le guide d'instructions Sanyo).

Un test simple (`tests.zig`) :

```zig
test "ADD immediate VMC-156" {
    var rom: [65536]u8 = undefined;
    var cpu = makeCpu(&rom);
    rom[0] = 0x81; rom[1] = 0x13;
    cpu.a = 0x55;
    _ = step(&cpu);
    try testing.expectEqual(@as(u8, 0x68), cpu.a);
}
```

- On crée une ROM de 64 Ko et un CPU.
- On place les octets du programme directement en mémoire (`0x81, 0x13` = `ADD #13H`).
- On pose `A = 0x55`, on exécute une instruction, et on vérifie `A == 0x68`
  (`0x55 + 0x13 = 0x68`), provable en hexadécimal.

> **Zig** : `@memset(rom, 0)` met la ROM à zéro (comme `memset` en C). `_ = step(&cpu)`
> signifie « ignore la valeur de retour » (Zig oblige à utiliser les valeurs de retour non
> utilisées, ou à les ignorer explicitement avec `_`).

### Lancer les tests

```
zig build test
```

La sortie doit indiquer `92/92 tests passed`. Les tests sont des garde-fous : ils confirment
que les modifications du code ne cassent pas le comportement des instructions.

---

## Annexe A — Petite référence Zig rapide

| Concept | Syntaxe | Exemple |
|---------|---------|---------|
| Entier non signé | `u8`, `u16`, `u32` | `var x: u8 = 10;` |
| Entier signé | `i8`, `i16` | `var y: i16 = -5;` |
| Constante | `const` | `const SCALE: i32 = 10;` |
| Constante de compilation | `const X = ...;` | valeurs calculées à la compile |
| Wrap arithmetic | `+%`, `-%`, `*%` | `x +%= 1;` (déborde proprement) |
| Rang | `0...0xFF` | intervalle inclusif |
| Test de bit | `val & (1 << bit)` | non nul ⇒ bit à 1 |
| AND/OR/NOT bit à bit | `&`, `\|`, `~` | `buttons &= ~0x01;` (éteindre bit 0) |
| Conversion | `@as`, `@intCast`, `@truncate`, `@bitCast` | affinage / troncature / réinterprétation |
| Option (nullable) | `?T` | `var val: ?Interruptions = null;` |
| Déballage option | `if (x) \|v\| ...` | traiter la valeur contenue |
| Fallback | `orelse` / `catch` | défaut si null / si erreur |
| Switch sur enum | `switch (x) { .a => ..., }` | dispatch typé |
| Package `enum` | `packed struct(u8)` | champs dans les bits d'un octet |
| Test | `test "nom" { ... }` | test unitaire |
| Ignorer une valeur | `_ = expr;` | Zig exige l'usage ou l'ignorance explicite |

---

## Annexe B — Lexique des termes du projet

| Terme | Signification |
|-------|---------------|
| **Opcode** | L'octet qui encode une instruction |
| **SFR** | Special Function Register — registre de contrôle du matériel |
| **SFR offset** | Position du registre dans la plage 0x100-0x17F |
| **fBST** | Fréquence du quartz RTC = 32 768 Hz |
| **IRQ / ISR** | Interruption / son gestionnaire (routine de service) |
| **Vecteur** | Adresse fixe où le CPU saute pour un type d'IRQ |
| **Flag** | Un bit qui signale un événement (souvent un débordement) |
| **Enable** | Un bit qui « autorise » une fonction |
| **INT** | Interruption |
| **EA** | Master Interrupt Enable (bit 7 de IE) |
| **FAT** | File Allocation Table — table reliant les blocs d'un fichier |
| **FAT_LastInFile** | Marqueur (0xFFFA) = dernier bloc d'un fichier |
| **Bloc** | Unité de 512 octets de la flash |
| **Root** | Bloc racine (en-tête du volume) |
| **XRAM** | Mémoire de l'écran LCD |
| **Active-low** | Un signal actif à l'état bas (0 = appuyé) |
| **BCD** | Encodage des chiffres décimaux dans des demi-octets |

---

*Document généré pour faciliter la prise en main du code. Il décrit uniquement les éléments
effectivement implémentés dans le projet. Pour le détail des timers par rapport au manuel,
voir aussi `doc/doc_timer.md`.*
