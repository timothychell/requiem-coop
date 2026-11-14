# Pitfalls (tooling)

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
