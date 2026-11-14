# CLAUDE.md — Requiem Co-op

Two-player co-op mod for Resident Evil Requiem (Steam app 3764200): REFramework Lua + a C++ REFramework
plugin for Steam networking. Read this file first; it exists so you don't re-discover things.

## Documentation rule (do this every session)

- **After every feature, fix or non-obvious discovery, add 1–5 lines here** (Engine facts, Known issues,
  or Pitfalls), plus a CHANGELOG.md entry for user-visible changes. Short, factual, with the *why*.
- Prefer a line here over re-deriving it next time. If a fact turns out wrong, correct or delete it.
- Longer write-ups go in `tools/*.md` (PERFORMANCE_AUDIT, PROTOCOL_AUDIT, SESSION_SYNC); link them here.
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

## Remote control (DEBUG builds only)

- `require/requiem_coop_rc.lua` lets the **host** drive a **connected client** the way the local bridge
  drives the host. The main script wires it via `pcall(require)` → `_G.__requiem_coop_rc`; the file is
  **excluded from release** (`package.ps1` removes it unless `-Debug`), so release clients have no code
  path that runs host-sent commands. Routing stubs in `handle_event` (`rcexec/rcload/rcfile/rcres/rcack`)
  are inert when the handle is nil.
- **Consent-gated.** The client must set `cfg.allow_remote_control` ("Allow host remote control", Options)
  or every request returns `{denied}`. When on, an on-screen banner is drawn every frame. Flip
  `DEFAULT_ALLOW` in the module only for your own throwaway debug builds.
- Host API (call via bridge or MCP): `__requiem_coop_rc.exec_peer(code)` / `deploy_peer(relpath,bytes)` /
  `deploy_peer_b64(relpath,b64)` / `reload_peer(path)` each return a **ticket**; poll `rc.result(ticket)`
  → `{pending}` | `{done, ok/value|err|denied, ...}`. It's async (round-trips to the peer over the
  reliable event channel, chunked ~40 KB); the bridge can't block for it — issue, then poll.
- Client file writes go through `fs.write`, which is rooted at `reframework/data`; a requested path is
  written under `reframework/data/` (or `_deploy/<name>` fallback) and the actual path is reported.
  Absolute paths and `..` are rejected. Can't hot-swap a *loaded* DLL; deploy stages it for next launch.
- **MCP**: `tools/mcp/requiem-coop-mcp.js` (dependency-free Node stdio) exposes `coop_status`, `game_eval`
  (local) and `peer_eval`/`peer_status`/`peer_deploy_file`/`peer_reload` (client). It drives the dev
  bridge, so the bridge must be enabled. `.mcp.json` (repo root) registers it when Claude runs from the
  repo; from the game folder use `claude mcp add requiem-coop -- node "<repo>/tools/mcp/requiem-coop-mcp.js"`.
- **b64 pitfall (fixed):** the module's base64 decoder must decode 4 chars→3 bytes at a time; the first
  version accumulated all sextets into one Lua number and lost precision past a few bytes (silent
  corruption). Round-trip verified in-game (250 bytes exact). Keep `b64enc`/`b64dec` symmetric.

## Debugging a live session

- Host requests the partner's read-only report: bridge `coopnet.send_event("dbgreq:1")` → wait for
  `<game>\reframework\data\coop_partner_debug.json` (partner must tick "allow debug requests").
- Host state: `_G.__requiem_coop_debug()`, session object `_G.__requiem_coop_session_live`
  (`S.E` = engine adapter: `play/freeze/unfreeze/skip/playing/current_id`), menu
  `_G.__requiem_coop_title_menu.menu`, internals `_G.__requiem_coop_internals`.
- `coop_net_log.txt` only logs events **received** from the partner and UI commands — not what we send.
- Screenshot: `./tools/Capture-GameWindow.ps1 -OutputPath <scratch png>` then view it.
- Ask for the partner's debug info **immediately** when something breaks; reports show only current state.

## Engine facts (verified in-game)

- **Lua main chunk is at the 200-local limit.** Add state as fields of existing tables (`anim.*`, `visual.*`,
  `world.*`, `lobby.*`, `JM.*`) or inside `do ... end` blocks.
- Reflected call ≈1.3 µs; resolve methods once (`td:get_method`) for hot paths. Resource-holder getters
  (`get_MotionBankAsset`, `get_SkeletonResourceHandle`, `getMesh`) allocate a new wrapper per call
  (0.2–0.76 ms) — never call per frame, never use their addresses as cache keys.
- **GUI writes only stick in the update phase** (`re.on_pre_application_entry("LateUpdateBehavior")`), not in
  `re.on_frame` / the bridge. Text: `set_MessageId(ValueType.new(System.Guid))` then `set_Message(str)`.
- Managed enum arrays: element data at offset `0x20`, 4 bytes each (`arr:write_dword`).
- `findComponents` can return a non-array object around scene changes — read arrays defensively.
- No player exists in opening cinematics → area/position are nil; normalise (area `''`).
- REFramework plugins must not run worker threads (REFramework suspends threads while hooking → deadlock).
- Occasional REFramework hang while installing hooks at game start (AppHang in the event log) — relaunch.

**Title menu** (`app.UI1010GuiBehavior`): rows come from `updateItems(GuiTitleSelectType[],default,bool)`
(pre-hook, swap `args[3]`). Real input calls compiler-generated callbacks, **not** `onSelectItemDecided`:
`<setupScrollListHelper>b__9_0` = decided, `b__9_1` = canceled. The helper switches its input off on decide
→ re-enable with `setInputEnable(true,false)` when skipping the game's handling. `CallbackArgs` can't be
constructed from Lua (keep a real one). Main Story's submenu is the same object — leave non-title lists alone.
Guide line = `Gui_ui0400` → `type1/m_text`. The game's list has a hidden entry (type 10): don't compare counts.

**Cutscenes** (`app.TimelineEventMediator` / `app.TimelineEventProcess`): hooks on `playImpl`, `skip`,
`onStartingEvent/onFinishedEvent`. `play(...)` returns true on *acceptance*; loading takes seconds before
`IsPlayingCutScene` — never re-request while loading. `process:pause(key)/resume(key)` freeze a running scene
(state 8↔9, `canPause()` true ~0.1 s after start, still counts as playing). Mod-started scenes render fine.
`load(id,...)` returns false for arbitrary IDs (can't preload). Cutscene frame position is **not** readable via
scene `via.timeline.Timeline` components (those are unrelated filters) — `E.tracks` correction is ineffective.
**Never block the game's own play call** (returning SKIP_ORIGINAL then playing later skipped a story sequence
and froze input in a real session).

**Motion**: player has dynamic motion banks (first-person); replicated via the 5th descriptor field.
`TreeLayer.changeLocalBankType` restarts the motion — never call per frame.

**Saves**: per-slot `data%03dSlot.bin`, encrypted with seed = SteamID (hook `get_EncryptionSeed`); a file only
loads from its own slot id. See README "What happens to the partner's saves".

## Protocol rules

- Every new optimisation/feature on the wire is **negotiated** (capability event, e.g. `anstate:2`,
  session3 `barrier=1`); older peers keep the old format.
- **Every new event kind must be added to the main script's router** (`handle_event`; session kinds in the
  `if session and (k=="..." ...)` list). `tools/test_routing.lua` enforces this — it broke real sessions twice.
- Session tests (`test_session_sync.lua`) call the library directly with a simulated engine; they do **not**
  cover main-script routing or real engine timing. Add an in-game check for anything engine-facing.

## Known issues / status

- Cutscene pause barrier (0.12.0): verified pieces in-engine; **full two-PC flow not yet verified**.
  Cross-area cutscenes not synced (needs area transitions). No drift correction during playback.
- Partner avatars not shown (game UI shows only texture files; Steam gives raw pixels).
- `link.connected` from the plugin means "pose packets in the last 3 s", **not** session connectivity
  (it's false on the title screen and in cutscenes). Use `partner_present()` for "in a session".
- Combat effects, grabs/finishers, breakable boxes, full cloth physics, area transitions: not synced.
- Enemy authority = closest player; attacks against the non-owner not fully verified.

## Pitfalls (tooling)

- PowerShell: `R` is a built-in alias (don't name helpers `R`); variable names are case-insensitive
  (`$r` overwrites `$R`); `[IO.File]` resolves relative paths against the process cwd (the game folder) —
  always use absolute paths; `Set-Content -Encoding utf8` writes a BOM (use `[IO.File]::WriteAllText` with
  `UTF8Encoding($false)`). Inline Lua through `-Code` breaks on PowerShell quote escaping — prefer here-strings.
- Bridge globals are sandboxed: set parameters via `_G.name` explicitly.
- The bridge writes `bridge_cmd.json`; a locked file is retried by `Invoke-CoopBridge.ps1`.
- `tools/*.json` / `*.png` are local outputs and git-ignored (they can contain Steam names/IDs).
- Auto mode refuses compiling downloaded code (e.g. stock Lua) — tests run in-game instead.
- Don't kill/restart the user's game or leave/host Steam lobbies without asking; check `coop_link.json`
  (`mode`, `peer`) before anything that changes the session.
- Testing in the user's game: suppress session relay during probes (`S.handle=function() end; S.cap=false`,
  restore afterwards) so the partner isn't affected.
