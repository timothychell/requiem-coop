# Remote control (DEBUG builds only)

Lets the **host** drive a **connected client** the way the local dev bridge drives the host: run Lua in the
client's REFramework, read its state, deploy files, and hot-reload Lua on it. For debugging two-PC sync; it
is **not** in release builds. See also `tools/mcp/README.md`.

- `require/requiem_coop_rc.lua` is wired by the main script via `pcall(require)` → `_G.__requiem_coop_rc`; the
  file is **excluded from release** (`package.ps1` removes it unless `-Debug`), so release clients have no code
  path that runs host-sent commands. Routing stubs in `handle_event` (`rcexec/rcload/rcfile/rcres/rcack`) are
  inert when the handle is nil, so a release/older peer ignores the events.
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
