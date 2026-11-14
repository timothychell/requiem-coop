# CLAUDE.md — Requiem Co-op

Two-player co-op mod for Resident Evil Requiem (Steam app 3764200): REFramework Lua + a C++ REFramework
plugin for Steam networking. Read this file first; it exists so you don't re-discover things.

## Documentation rule (do this every session)

- **After every feature, fix or non-obvious discovery, add 1–5 lines to the matching `docs/` file**
  (see the index below — e.g. `docs/engine-facts.md`, `docs/known-issues.md`, `docs/pitfalls.md`), plus a
  CHANGELOG.md entry for user-visible changes. Short, factual, with the *why*.
- Keep **CLAUDE.md** itself thin: intro, this rule, the Layout table, the Workflow, and the docs index.
  Reference material lives in `docs/`; detailed audits stay in `tools/*.md`. Don't grow CLAUDE.md back out.
- Prefer a line in `docs/` over re-deriving it next time. If a fact turns out wrong, correct or delete it.
- Never put personal data (names, Steam IDs, emails, user paths) in committed files.

## Layout

| Path | What |
|---|---|
| `mod/reframework/autorun/requiem_coop.lua` | Main script (~4k lines): puppet, animation, protocol, lobby, save handoff, world sync, UI |
| `mod/.../require/requiem_coop_session.lua` | Session library: cutscenes (barrier, skip votes), mission event journal, torches |
| `mod/.../require/requiem_coop_menu.lua` | Native title-menu "Co-op" entry + lobby |
| `mod/.../require/requiem_coop_rc.lua` | **DEBUG ONLY** remote control: host drives a connected client's REFramework (absent from release) |
| `plugin/requiem_coop_net.cpp` | REFramework plugin DLL: Steam lobby/P2P, UDP fallback, save transfer, `coopnet` Lua table |
| `tools/` | Bridge client, in-game test suites, probes, audits. `tools/dev/requiem_bridge.lua` = dev bridge |
| `tools/mcp/requiem-coop-mcp.js` | MCP server: exposes the game (and a consenting client) to an MCP client via the bridge |
| `package.ps1` | Builds DLL + zip → `dist/RequiemCoop-<ver>.zip` (`-Debug` includes remote control) |

## Workflow

1. **Edit** files in the repo (never edit the installed copies in the game folder).
2. **Compile-check** through the bridge before installing (the game must be running, bridge enabled):
   `./tools/Invoke-CoopBridge.ps1 -Code "local f,e=loadfile([[<repo>\mod\...\requiem_coop.lua]]); return {ok=f~=nil,e=e}"`
3. **Install** = copy changed Lua files to `<game>\reframework\autorun\` (and `require\`).
4. **Hot reload**: bridge `dofile([[<game>\reframework\autorun\requiem_coop.lua]])`. A GEN guard disables
   older copies; the require modules are reloaded by the main script (`package.loaded[...] = nil`).
   The **DLL can't be replaced while the game runs** — it needs a restart.
5. **Test**: `./tools/Run-Tests.ps1` (runs all suites in the game's own Lua; game folder auto-detected via
   Steam, override with `-GameRoot` / `REQUIEM_GAME_ROOT`). All must pass before committing.
6. **Package**: `powershell -ExecutionPolicy Bypass -File package.ps1 -Version X.Y.Z-preview`.
7. **Commit/push**: branch `main`, remote GitHub. Write the message to a UTF-8 file without BOM and use
   `git commit -F <file>` (PowerShell here-strings passed inline don't reach git; BOM ends up in the subject).
   `.github/workflows/build.yml` is untracked locally: the gh token lacks the `workflow` scope
   (`gh auth refresh -h github.com -s workflow` needed before it can be pushed).
8. **Versioning**: bump `anim.MOD_VERSION` (main script) + header comment + README status + CHANGELOG for any
   protocol change. Peers exchange `modver:` and the UI warns on mismatch. Both players must run the same zip.

## Documentation (`docs/`)

Reference material lives in `docs/` (keep each short and factual; add to the matching file as you learn things):

| File | What's in it |
|---|---|
| [docs/engine-facts.md](docs/engine-facts.md) | Verified in-game engine behaviour: reflection cost, GUI update phase, title menu, cutscenes, motion, saves. |
| [docs/protocol.md](docs/protocol.md) | Wire protocol rules: capability negotiation, the event router, what the tests do/don't cover. |
| [docs/remote-control.md](docs/remote-control.md) | **DEBUG-only** host remote control of connected clients + the MCP server. |
| [docs/debugging.md](docs/debugging.md) | Inspecting a live two-PC session (partner debug report, host globals, screenshots). |
| [docs/known-issues.md](docs/known-issues.md) | Current limitations and not-yet-synced systems. |
| [docs/pitfalls.md](docs/pitfalls.md) | Tooling gotchas: PowerShell, the bridge, git-ignored outputs, don't-disrupt-the-session rules. |

Deeper one-off audits: `tools/PERFORMANCE_AUDIT.md`, `tools/PROTOCOL_AUDIT.md`, `tools/SESSION_SYNC.md`.
