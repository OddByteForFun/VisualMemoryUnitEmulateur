<!-- bmad:context -->
<!-- Verified 2026-08-25 against 4c3b733. Managed by bmad-project-context;
     edits inside this block are replaced on refresh. -->

# LC86000

Emulator for the Sanyo LC86K87 (the Dreamcast VMU's 8-bit CPU), written in Zig 0.16
with raylib rendering. Hardware ground truth is `doc/VMU.pdf`; roadmap lives in `README.md`,
architecture and emulation-loop call order in `concept.md`.

## Policy

### Commits

- Format: `<icon> <type>: <summary>` — Conventional Commits, English, imperative mood,
  ≤ 72 chars, no trailing period. One logical change per commit.
  | Icon | Type | Use |
  |------|------|-----|
  | ✨ | `feat:` | new feature |
  | 🐛 | `fix:` | bug fix |
  | ♻️ | `refactor:` | restructure, no behavior change |
  | ⚡ | `perf:` | performance improvement |
  | ✅ | `test:` | tests only |
  | 📝 | `docs:` | documentation only |
  | 🔧 | `chore:` | build, tooling, housekeeping |

### Pushes

- Direct pushes to main are allowed; never force-push or rewrite history on main.
- `zig build test` must pass before every push.

## Where things are

- Instruction status matrix: `doc/doc_inst.md` · timer behavior: `doc/doc_timer.md`
- ISA table and addressing modes: `isa.zig` · VMU-specific logic (flash, BIOS): `vmu.zig`
- When encoding hardware behavior in code, cite the VMU.pdf table/page in the comment
  (existing convention, e.g. lc86K.zig SFR defaults).

## Running and verifying

- `zig` is NOT on PATH — invoke the VS Code-managed 0.16.0 toolchain directly:
  `& "$env:APPDATA\Code\User\globalStorage\ziglang.vscode-zig\zig\x86_64-windows-0.16.0\zig.exe" build test`
  (verified: 92/92 tests pass with this binary)

## Conventions that differ from defaults

- Target is Zig 0.16 (`build.zig.zon`): use the new I/O interface (`std.process.Init`,
  `std.Io.Dir`) as `main.zig` does — pre-0.15 `std.io` idioms do not compile here.
- Code comments and docs are written in French (commit messages: English, see Policy).

## Known pitfalls

- `zig build test` used to report failure despite all tests passing — caused by `[BIOS]` stderr
  output from `debug.zig`. Fixed by setting `dbg.log_level = .none` in `makeCpu()` and
  removing redundant `std.debug.print` from `reportBiosPhase`.
