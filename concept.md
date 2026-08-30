# Architecture de l'émulateur LC86000 (VMU Dreamcast)

## Présentation

Émulateur du **Sanyo LC86K87** (CPU 8-bit du VMU Dreamcast) écrit en **Zig**. Il charge un BIOS et un jeu VMS, émule le CPU, les timers, les interruptions, l'écran LCD 48×32, et les boutons. Le rendu est fait avec **raylib**.

---

## Structure des fichiers

| Fichier | Rôle |
|---------|------|
| `main.zig` | Point d'entrée : CLI, boucle principale, rendu LCD, entrées clavier |
| `lc86K.zig` | Définition du CPU (registres, mémoire, timers, interruptions, SFRs) |
| `decode.zig` | Décodeur/exécuteur des 70 instructions + compteur de cycles |
| `debug.zig` | Logging, désassembleur, détection de boucle |
| `tests.zig` | 92 tests unitaires |

---

## Ordre d'appel général (boucle d'émulation)

### 1. Démarrage (`main.zig`)

```
main()
  ├── parseArgs()              → lit les flags --azerty, --trace, chemins BIOS/ROM
  ├── loadBIOS(rom)            → charge le BIOS dans un buffer 64KB
  ├── cpu = Cpu.init(rom)      → initialise le CPU avec le BIOS
  ├── initVmuFlash(&cpu)       → crée un système de fichiers FAT flash valide
  ├── loadGame(game)           → charge le jeu dans flash block 0
  ├── createDirEntry()         → crée l'entrée de répertoire du jeu (block 253)
  ├── setupFATChain()          → chaîne FAT blocks 0 → 1 → ... → LastInFile
  ├── cpu.reset()              → reset du CPU (PC=0, registres=0, SFRs defaults)
  ├── initBiosRtc(&cpu)        → pré-date la RTC BIOS + skip query série
  ├── dbg.init()               → initialise le logging
  ├── rl.initWindow()          → ouvre la fenêtre raylib
  │
  └── boucle principale (while !windowShouldClose)
        ├── flushLogFile()     [toutes les 60 frames]
        ├── rl.pollInputEvents() → rafraîchit l'état des entrées
        ├── updateButtons(&cpu)  → lit le clavier → met à jour cpu.p3_buttons
        ├── rl.getKeyPressed()   → log toutes les touches pressées
        │
        ├── for 0..cycles_per_frame (100 000 cycles par frame)
        │     ├── step(&cpu)     → exécute 1 instruction (decode.zig)
        │     ├── cycles++
        │     └── si cpu.halted
        │           ├── tickTimers(batch) + requestLevelDrivenInterrupts + servicePendingInterrupt
        │           └── wakeup si P3 change
        │
        ├── rl.beginDrawing()
        ├── renderLcd(&cpu)     → affiche l'écran VMU via raylib
        ├── rl.drawText()       → infos debug (PC, cycles, etc.)
        ├── rl.endDrawing()
        └── frames++
```

### 2. Boucle d'exécution CPU (`step` dans `decode.zig`)

```
step(cpu)
  ├── si halted → tickTimers(1) + requestLevelDrivenInterrupts + servicePendingInterrupt
  │               + wakeup si P3 change → return 1
  │
  ├── dbg.recordPC(cpu.pc)     → détection de boucle
  ├── opcode = cpu.fetch8()    → lit 1 octet à PC, PC++
  ├── dec = decodeOpcode(opcode) → table 16×16 → Inst + AddressingMode
  │
  ├── si trace → dbg.disassembleAt() + log()
  │
  ├── switch(dec.inst)         → exécute l'instruction
  │     ├── .nop: rien
  │     ├── .br, .brf: branchement relatif
  │     ├── .bz, .bnz: branchement conditionnel (A==0 / A!=0)
  │     ├── .add, .addc, .sub, .subc: opérations arithmétiques
  │     ├── .and, .or, .xor: opérations logiques
  │     ├── .inc, .dec: incrémente/décrémente mémoire
  │     ├── .ld, .st, .ld_ri, .st_ri: load/store depuis vers adresse
  │     ├── .push, .pop: pile
  │     ├── .mul, .div: multiplication/division 16-bit
  │     ├── .call_a12, .callr, .callf: appels de sous-routine
  │     ├── .ret, .reti: retour (reti = retour d'interruption)
  │     ├── .jmpf: saut avec bank switch (synchronisation différée)
  │     ├── .jmp_a12: saut dans la même page 4KB
  │     ├── .ldc: load depuis ROM via (TRR + ACC)
  │     ├── .ldf, .stf: load/store flash à 17-bit
  │     ├── .set1, .clr1, .not1: manipulation de bits mémoire
  │     ├── .bp, .bn, .bpc: branchement sur bit (bpc test+clear)
  │     ├── .be, .bne: branchement sur égalité (avec mise à jour carry)
  │     ├── .dbnz: decrement and branch if not zero
  │     ├── .mov, .mov_ri: move immédiat vers mémoire
  │     ├── .xch: échange ACC avec mémoire
  │     ├── .ror, .rol, .rorc, .rolc: rotations avec/sans carry
  │     └── .ldf, .stf: lecture/écriture flash via TRR
  │
  ├── used = cycles(dec)       → nombre de cycles CPU de l'instruction
  ├── cpu.tickTimers(used)     → tick tous les timers
  │     ├── tickTimer0()       → Timer 0 (prescaler + mode 0/2)
  │     ├── tickTimer1()       → Timer 1 (mode 0/2)
  │     └── tickBaseTimer()    → Base Timer (14-bit, quartz 32.768kHz)
  │
  ├── cpu.requestLevelDrivenInterrupts() → vérifie P3 (boutons)
  ├── cpu.servicePendingInterrupt()      → priorité et dispatch IRQ
  └── return used
```

---

## Rôle détaillé de chaque fonction

### `main.zig`

| Fonction | Rôle |
|----------|------|
| `main()` | Point d'entrée. Parse les arguments CLI, charge BIOS et jeu, appelle `init()`, puis `reset()`, puis la boucle d'émulation 60 FPS |
| `initVmuFlash(cpu)` | Initialise la flash 128KB avec un système de fichiers FAT conforme VMU : block root (255), FAT (254), directory chain (253→241), marquage des blocs |
| `initBiosRtc(cpu)` | Pré-initialise la RTC du BIOS pour éviter l'attente du query série Dreamcast : écrit la date en RAM, configure les SFRs, jump direct à PC=0x2E1 |
| `renderLcd(cpu)` | Rendu de l'écran LCD 48×32 pixels (monochrome) via raylib. Lit les pixels depuis XRAM via `getXramByte()`, dessine à l'échelle 10× |
| `getXramByte(cpu, row, col)` | Lit un octet (8 pixels horizontaux) depuis la XRAM (banque 0 pour lignes 0-15, banque 1 pour 16-31) |
| `updateButtons(cpu)` | Mappe le clavier (QWERTY ou AZERTY) sur le port P3 : 6 boutons + Mode + Sleep |
| `flushLogFile(init)` | Vide le buffer de log dans `vmu_trace.log` sur disque |

### `lc86K.zig` (CPU)

| Fonction/Méthode | Rôle |
|------------------|------|
| `Cpu.init(rom)` | Constructeur : initialise tous les registres, RAM, SFRs (valeurs reset hardware VMU), flash, XRAM, work_ram |
| `Cpu.reset()` | Reset complet : PC=0, tous les compteurs timers à 0, SFRs reset hardware, inst_bank → ROM |
| `Cpu.syncInstructionBank()` | Applique le bank switch différé (stocké dans `pending_ext`) : ROM, FlashBank0 ou FlashBank1 selon Ext3/Ext0 |
| `Cpu.setInstructionBank(bank)` | Change directement la banque d'instructions (pour tests/UI) sans passer par pending_ext |
| `Cpu.currentRamBank()` | Retourne ram_bank0 ou ram_bank1 selon PSW.rambk0 |
| `Cpu.load8(addr)` | Charge un octet depuis l'espace d'adressage 9-bit (0x000-0x1FF) : 0x00-0xFF = RAM, 0x100-0x17F = SFR, 0x180-0x1FF = XRAM |
| `Cpu.store8(addr, val)` | Écrit un octet dans l'espace d'adressage 9-bit avec routage automatique (RAM/SFR/XRAM) |
| `Cpu.loadSFR(offset)` | Lecture d'un registre SFR : retourne les registres CPU (A, B, C, SP, TRL, TRH, PSW) ou les compteurs timers, ou P3 (boutons), ou VTRBF (work RAM) |
| `Cpu.storeSFR(offset, val)` | Écriture d'un SFR avec side-effects : mise à jour des registres CPU, reload timers quand RUN=0, gestion HALT (PCON.0), bank switch différé (EXT), auto-incrément VRMAD |
| `Cpu.loadXram(offset)` | Lecture XRAM selon XBNK (banque 0/1/2) avec masque dead columns (0xC-0xF) |
| `Cpu.storeXram(offset, val)` | Écriture XRAM avec masque dead columns |
| `Cpu.fetch8()` | Lit l'octet à PC dans la banque d'instructions courante, puis PC++ |
| `Cpu.fetch16()` | Lit 2 octets (little-endian) via fetch8 |
| `Cpu.read16At(addr)` | Lit 2 octets depuis l'espace d'adressage 9-bit |
| `Cpu.write16At(addr, val)` | Écrit 2 octets dans l'espace d'adressage 9-bit |
| `Cpu.readFlash()` | Lit la flash à adresse 17-bit = TRL \| (TRH<<8) \| (FPR.bit0 ? 0x10000 : 0) |
| `Cpu.writeFlash(val)` | Écrit dans la flash à adresse 17-bit |
| `tickTimer0(cycles)` | Incrémente le prescaler du Timer 0. Quand prescaler atteint (256 - T0PRR), tick le compteur selon le mode |
| `tickTimer1(cycles)` | Tick Timer 1 (sans prescaler) : mode 0 (2×8-bit) ou mode 2 (16-bit cascade) |
| `tickBaseTimer(cycles)` | Tick du Base Timer 14-bit (quartz 32.768kHz). SET BT0_FLAG/BT1_FLAG selon seuils configurés. Un tick fBST ≈ 183 cycles CPU |
| `tickTimers(cycles)` | Appelle tickTimer0 + tickTimer1 + tickBaseTimer |
| `incrementT0Mode0()` | Timer 0 mode 0 : deux timers 8-bit indépendants avec reload et flags overflow |
| `incrementT0Mode2()` | Timer 0 mode 2 : timer 16-bit cascade avec auto-reload |
| `incrementT1Mode0()` | Timer 1 mode 0 : deux timers 8-bit indépendants avec reload |
| `incrementT1Mode2()` | Timer 1 mode 2 : timer 16-bit cascade (T1L overflow → T1H) |
| `requestLevelDrivenInterrupts()` | Vérifie l'état de P3 (boutons) et positionne P31INT en mode continuous ou edge |
| `servicePendingInterrupt()` | Vérifie les flags d'interruption (timer 0, base timer, timer 1, P3) par priorité. Si une IRQ est pendante : push PC sur la pile, jump au vecteur, clear le flag, set interrupt_depth=1 |

### `decode.zig`

| Fonction | Rôle |
|----------|------|
| `decodeOpcode(opcode)` | Décode un opcode 8-bit → structure `DecodeResult` avec l'instruction, le mode d'adressage, registre indirect, bit. Table 16×16 (row=high nibble, col=low nibble) |
| `cycles(dec)` | Retourne le nombre de cycles CPU pour chaque instruction (1-7 cycles) |
| `step(cpu)` | Fonction principale d'exécution. Voir §2 ci-dessus |
| `signExt8(val)` | Extension de signe 8→16 bits pour les branchements relatifs |
| `readIndirectAddr(cpu, ri)` | Calcule l'adresse indirecte 9-bit depuis RAM bank0 à partir du champ IRBK (PSW bits 3-4) et du registre Ri |
| `decodeD9addr(dec, cpu)` | Décode une adresse directe 9-bit (D9) : fetch 8-bit + bit supplémentaire depuis l'opcode |
| `readEA(cpu, dec)` | Lit l'adresse effective selon le mode : D9 ou Ri |
| `readOp8(cpu, dec)` | Lit l'opérande 8-bit selon le mode : immédiat, direct (load depuis adresse), ou indirect |
| `decodeD9(opcode, val)` | Calcule une adresse 9-bit depuis un opcode et une valeur 8-bit |

### `debug.zig`

| Fonction | Rôle |
|----------|------|
| `init()` | Initialise le ring buffer de log, le file buffer |
| `enableFileLog()` / `disableFileLog()` | Active/désactive la journalisation fichier |
| `getLogData()` | Retourne le buffer fichier |
| `clearLogData()` | Vide le buffer fichier |
| `log(fmt, args)` | Formate et enregistre un message dans le ring buffer + fichier (si activé) |
| `logLine(line)` | Enregistre une ligne pré-formatée |
| `getRingLine(idx)` | Lit une ligne du ring buffer |
| `disassembleAt(cpu, buf, pc)` | Désassemble l'instruction à l'adresse PC dans un buffer texte. Utilise la même table 16×16 que le décodeur |
| `recordPC(pc)` | Enregistre le PC pour détection de boucle (fenêtre de 128 échantillons, boucle si >85% identiques) |
| `formatCpuState(cpu, buf)` | Formate l'état des registres CPU pour debug |
| `formatSfrState(cpu, buf)` | Formate l'état des SFRs timers pour debug |
| `instSize(rom, addr)` | Calcule la taille d'une instruction en octets |

---

## Hiérarchie des appels (qui appelle qui)

```
main.zig:main()
  │
  ├── Cpu.init()              [lc86K.zig]
  ├── initVmuFlash()          [main.zig]
  ├── cpu.reset()             [lc86K.zig]
  ├── initBiosRtc()           [main.zig]
  ├── dbg.init()              [debug.zig]
  │
  └── Boucle frames (60 FPS)
        │
        ├── updateButtons()   [main.zig]
        │
        ├── Boucle cycles (100 000 / frame)
        │     │
        │     └── decode.zig:step(cpu)
        │           │
        │           ├── cpu.fetch8()              [lc86K.zig]
        │           ├── decodeOpcode()            [decode.zig]
        │           ├── [switch inst] ─── lit/cpu.load8(), cpu.store8(), etc.
        │           │     ├── readEA() → decodeD9addr() ou readIndirectAddr()
        │           │     ├── readOp8() → cpu.fetch8() ou cpu.load8()
        │           │     ├── cpu.syncInstructionBank() (jmpf only)
        │           │     ├── cpu.readFlash() / writeFlash() (ldf/stf)
        │           │     └── cpu.ram_bank0[...] (push, pop, call, ret, reti)
        │           │
        │           ├── cycles(dec)
        │           ├── cpu.tickTimers(used)      [lc86K.zig]
        │           │     ├── tickTimer0()
        │           │     │     ├── incrementT0Mode0()
        │           │     │     └── incrementT0Mode2()
        │           │     ├── tickTimer1()
        │           │     │     ├── incrementT1Mode0()
        │           │     │     └── incrementT1Mode2()
        │           │     └── tickBaseTimer()
        │           │
        │           ├── cpu.requestLevelDrivenInterrupts()  [lc86K.zig]
        │           ├── cpu.servicePendingInterrupt()       [lc86K.zig]
        │           │     └── push PC → stack, PC = vecteur, clear flag
        │           │
        │           └── return used
        │
        ├── renderLcd()       [main.zig]
        │     └── getXramByte()  [main.zig]
        │
        └── flushLogFile()    [main.zig]
              ├── dbg.getLogData()
              └── write file
```

---

## Gestion des interruptions (priorité décroissante)

1. **INT2** (T0L overflow) — vecteur `0x0013` — Timer 0 low overflow
2. **INT3** (Base Timer) — vecteur `0x001B` — BT0 ou BT1 flag
3. **T0H** (Timer 0 high) — vecteur `0x0023`
4. **T1** (Timer 1) — vecteur `0x002B` — T1H ou T1L overflow
5. **P3** (Port 3) — vecteur `0x004B` — boutons (continuous ou edge)

Condition pour qu'une IRQ soit servie : `EA=1` (IE bit 7) ET `interrupt_depth == 0` (pas déjà dans une IRQ) ET `interrupt_blocked == 0` (période de blocage après écriture IE/IP).

---

## Espace mémoire

| Plage | Type | Détail |
|-------|------|--------|
| 0x000-0x0FF | RAM | Bank 0 (système+stack) ou Bank 1 (selon PSW.rambk0) |
| 0x100-0x17F | SFR | Registres de fonction spéciale (timers, ports, contrôle) |
| 0x180-0x1FF | XRAM | Mémoire LCD (3 banques : lignes 0-15, 16-31, icônes) |
| ROM / Flash | Instructions (64KB) | Bank switch selon EXT : BIOS ROM, Flash Bank 0 ou Flash Bank 1 |
| Flash 128KB | Données | 256 blocks × 512 bytes, système FAT VMU |
| Work RAM 512B | DMA Maple | Accès via VRMAD/VTRBF |

---

## Rôle des registres CPU

| Registre | Taille | Rôle |
|----------|--------|------|
| A (ACC) | 8-bit | Accumulateur principal (résultat des opérations) |
| B | 8-bit | Registre général / opérande multiplication/division |
| C | 8-bit | Registre général / partie basse multiplication |
| SP | 8-bit | Stack pointer (dans RAM bank 0) |
| PC | 16-bit | Program counter |
| TRL/TRH | 8-bit | Registre de base pour `ldc` (table reference) |
| PSW | 8-bit | Flags : P, rambk0, OV, IRBK0/1, AC, CY |
