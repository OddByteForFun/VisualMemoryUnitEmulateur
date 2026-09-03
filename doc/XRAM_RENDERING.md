# Implémentation du rendu XRAM réel pour le BIOS

## Changements effectués

### Rendu XRAM au lieu de menu texte simplifié

**Avant :**
- Pendant les phases BIOS, un menu texte simplifié s'affichait en dur (texte raylib blanc sur fond noir)
- Ce menu ne montrait pas ce que le BIOS réel écrivait dans la mémoire XRAM (LCD)

**Après :**
- **Toujours afficher le contenu bitmap d'XRAM** (ce que le CPU affiche réellement)
- Cela inclut aussi bien le BIOS que les jeux
- Affichage des informations de debug (PC, phase BIOS, compteurs) en overlay

## Fichiers modifiés

### `main.zig`

1. **Variables globales** (lignes 17-20)
   - ❌ Supprimé : `bios_menu_mode_flag`, `bios_menu_active`, `bios_menu_selected`, `bios_menu_index`
   - ✅ Ajouté : `game_started` (remplace `bios_menu_selected` avec un nom plus explicite)

2. **Rendu principal** (lignes 159-178)
   - ❌ Supprimé : condition `if (bios_menu_active and !bios_menu_selected)` → `drawBiosMenuScreen()`
   - ✅ Modifié : toujours appeler `renderLcd(&cpu)` pour afficher XRAM
   - ✅ Amélioration : afficher la phase BIOS en debug (string au lieu de juste le numero de sync)

3. **Détection du lancement du jeu** (lignes 139-151)
   - ❌ Supprimé : `bios_menu_selected`
   - ✅ Remplacé par : `game_started` (plus clair sémantiquement)

4. **Fonction `drawBiosMenuScreen()`**
   - ❌ Complètement supprimée (n'était qu'un placeholder)

5. **Parsing des flags CLI** (ligne 31)
   - ✅ Gardé : `--bios-menu` flag pour compatibilité CLI
   - ℹ️ Note : le flag est accepté mais ne change plus le comportement interne

6. **Initialisation BIOS RTC** (ligne 44)
   - ✅ Simplifié : `use_bios_menu = path_b != null` (pas besoin du flag interne)

## Comportement résultant

### Avant : Menu simplifié en dur
```
SEGA
Visual Memory
---

> game.vms

MODE to launch
```

### Après : Rendu réel du BIOS depuis XRAM
- Affiche bitmap pixel-par-pixel ce que le BIOS écrit dans la mémoire LCD (XRAM)
- Espace entièrement noir si le BIOS n'a rien écrit (normal au démarrage)
- Menu progressif au fur et à mesure que le BIOS trace son UI
- Interface visuelle authentique du VMU réel

## Implications techniques

### Avantages
1. **Authenticité** : on voit ce que le CPU écrit réellement, pas une simulation
2. **Debug** : plus facile de déboguer les écritures XRAM du BIOS
3. **Validation** : si le BIOS affiche correctement, on sait que XRAM fonctionne
4. **Simplicité** : code de rendu unifié (une seule fonction `renderLcd()`)

### Points à vérifier
1. Le BIOS écrit-il bien dans XRAM pendant ses phases ?
2. XRAM s'efface-t-il correctement entre les phases ?
3. Les icônes (bank2) s'affichent-elles correctement ?
4. Le texte du menu BIOS est-il lisible dans le rendu bitmap ?

## Prochaines étapes possibles

1. **UI du BIOS** : Implémenter un rendu réel du menu du BIOS (avec exploration de répertoire, horloge, etc.)
   - Nécessite d'analyser le BIOS réel pour comprendre où il écrit exactement
   
2. **Chassis VMU** : Ajouter un bezel/cadre pour ressembler à un vrai VMU physique
   - Écran LCD entouré de boutons, affichage LED, etc.

3. **Profondeur d'émulation** : Améliorer la fidélité du rendu LCD
   - Contraste (VCCR)
   - Refresh rate
   - Contrôle de l'affichage (MCR)

## Tests

✅ Compilation : `zig build test` passe (92/92 tests)
✅ Exécution : Programme lance sans erreur avec le rendu XRAM
