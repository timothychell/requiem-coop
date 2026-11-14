# Requiem Co-op MCP server (development only)

`requiem-coop-mcp.js` is a dependency-free Node stdio MCP server that gives an MCP client (e.g. Claude
Code) the same reach into the running game that the dev bridge gives — and, for **debug builds with a
consenting connected client**, the same reach into that client's PC.

It is a thin driver over the dev bridge (`tools/dev/requiem_bridge.lua`): every call writes
`reframework/data/bridge_cmd.json` and reads `bridge_out.json`. Nothing works unless the game is running
with **the Requiem Bridge enabled** (REFramework menu → Script Generated UI → Requiem Bridge).

## Tools

| Tool | Scope | What |
|---|---|---|
| `coop_status` | local | Connection status from `coop_link.json` (mode, connected, partner, rates). |
| `game_eval` | local | Run Lua in the local game's REFramework; returns the serialized result. |
| `peer_eval` | **client** | Run Lua in the connected client's REFramework; returns its result. |
| `peer_status` | **client** | The client's `__requiem_coop_debug()` snapshot (wrapper over `peer_eval`). |
| `peer_deploy_file` | **client** | Write a file onto the client (sandboxed to its `reframework/data`). |
| `peer_reload` | **client** | Ask the client to `dofile()` a path (hot-reload Lua it has). |

The `peer_*` tools require:
1. The **host** running a **debug build** (`require/requiem_coop_rc.lua` present — see `package.ps1 -Debug`).
2. A **connected partner** also on a debug build.
3. The partner having ticked **"Allow host remote control"** (Options). Otherwise the call returns
   `{ "denied": true }` and nothing runs on the client.

## Register it with Claude Code

Running Claude Code **from the repo root**, the committed `.mcp.json` is picked up automatically
(`node tools/mcp/requiem-coop-mcp.js`).

Running Claude Code **from the game folder** (or anywhere else), add it explicitly with an absolute path:

```
claude mcp add requiem-coop -- node "<path-to-repo>/tools/mcp/requiem-coop-mcp.js"
```

The server finds the game folder via `$REQUIEM_GAME_ROOT`, else by scanning Steam libraries. Set
`REQUIEM_GAME_ROOT` if auto-detection misses it.

## Safety

This is a debugging tool for your own co-op sessions. The remote-control reach only exists in debug
builds and only against a client that has explicitly opted in; the client shows a persistent on-screen
banner while it is enabled. Do not ship debug builds, and do not enable remote control on a machine you
do not control or whose owner has not agreed.
