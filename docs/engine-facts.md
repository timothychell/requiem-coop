# Engine facts (verified in-game)

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
