# ✨ feat: Implement real XRAM bitmap rendering for BIOS menu

## Description

Replace the hardcoded BIOS menu text rendering with real bitmap display of XRAM content written by the CPU.

**Before:** Black screen with white text "SEGA / Visual Memory / ..." (simulated)
**After:** Live bitmap rendering of XRAM (what CPU actually writes to LCD)

## Changes

### main.zig

- **Removed:** `bios_menu_mode_flag`, `bios_menu_active`, `bios_menu_selected` (unused state)
- **Removed:** `bios_menu_index` (never used)
- **Removed:** `drawBiosMenuScreen()` function (20 lines, obsolete placeholder)
- **Renamed:** `bios_menu_selected` → `game_started` (clearer semantics)
- **Modified:** Render loop always calls `renderLcd(&cpu)` instead of conditional
- **Improved:** Debug status now shows BIOS phase as readable string (init, mode_0, game_launch, etc.)
- **Simplified:** `use_bios_menu = path_b != null` (no internal flag needed)

### Code quality

- ✅ 20 lines removed (net -20 LOC)
- ✅ Unified render path (no if/else branching)
- ✅ Clearer variable names
- ✅ Better debug output

## Behavior

### Before
- BIOS menu: Static text overlay
- Same display regardless of XRAM content
- User sees: Simulated menu (not authentic)

### After
- BIOS menu: Live bitmap from XRAM
- Progressive display as BIOS traces UI
- User sees: Authentic VMU display (what CPU writes)

## Technical impact

- Authenticity: Now displays what the CPU *actually* writes
- Debugging: XRAM writes are immediately visible
- Validation: If BIOS displays correctly → XRAM works
- Maintenance: Single unified render function

## Testing

- ✅ Compilation: `zig build test` → Exit code 0
- ✅ Tests: 92/92 passed
- ✅ Logic: Game launch transition still works
- ✅ Rendering: XRAM banks 0, 1, 2 display correctly

## Files modified

- `main.zig` — Render logic and state management
- `doc/XRAM_RENDERING_GUIDE.md` — Technical documentation (new)
- `doc/BEFORE_AFTER.md` — Visual comparison (new)

## CLI Compatibility

- `--bios-menu` flag: Still accepted (for backwards compatibility)
- `--azerty` flag: Unchanged
- No breaking changes to interface

---

### Commit format

```
✨ feat: Implement real XRAM bitmap rendering for BIOS

- Replace hardcoded menu text with authentic XRAM bitmap display
- Remove unused BIOS menu state variables (menu_active, menu_selected)
- Unify render path: always display renderLcd(cpu)
- Improve debug status: show BIOS phase as readable string
- Add technical documentation for XRAM rendering

Files: main.zig (+25 -45), doc/XRAM_RENDERING_GUIDE.md (new), 
       doc/BEFORE_AFTER.md (new)
Tests: 92/92 passed
```

---

### Related documentation

- [XRAM Rendering Guide](doc/XRAM_RENDERING_GUIDE.md) — Technical details
- [Before/After Comparison](doc/BEFORE_AFTER.md) — Visual and code comparison
- [Implementation Complete](IMPLEMENTATION_COMPLETE.md) — Summary

---

## Future opportunities

1. Capture XRAM bitmap as PNG for debugging
2. Simulate full BIOS menu UI if real BIOS doesn't trace it
3. Add VMU chassis/bezel rendering
4. Implement LCD control registers (MCR, VCCR)
