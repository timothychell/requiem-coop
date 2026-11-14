# Known issues / status

- Cutscene pause barrier (0.12.0): verified pieces in-engine; **full two-PC flow not yet verified**.
  Cross-area cutscenes not synced (needs area transitions). No drift correction during playback.
- Partner avatars not shown (game UI shows only texture files; Steam gives raw pixels).
- `link.connected` from the plugin means "pose packets in the last 3 s", **not** session connectivity
  (it's false on the title screen and in cutscenes). Use `partner_present()` for "in a session".
- Combat effects, grabs/finishers, breakable boxes, full cloth physics, area transitions: not synced.
- Enemy authority = closest player; attacks against the non-owner not fully verified.
