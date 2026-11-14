# Changelog

Both players must use the same release. Install by extracting the zip into the game folder
(see the README). Every release is an experimental preview.

## 0.12.0-preview

- **Cutscene barrier rebuilt around freezing instead of holding.** 0.11.0 blocked the game's own "play
  cutscene" call and started it later. In the first real session that let the game's story logic run on
  without the cutscene: a sequence was skipped and both players lost input. Now:
  - The game's call is never blocked. Every copy of the scene starts for real and is frozen ~0.1 s in, using
    the engine's own pause (`TimelineEventProcess.pause/resume`, verified in-game). The game sees a real,
    running cutscene the whole time.
  - The other PC starts the same scene and freezes it too: through its own trigger after being moved next to
    the other player, or started by the mod.
  - When both are frozen, the host measures the round trip, sends "go" and unfreezes its own copy half a
    round trip later, so both resume at the same moment. A slower-loading PC holds the other at frame 0.
  - Watchdogs: no answer in 20 s, a dropped connection, a host that can't take part, or 30 s frozen all
    unfreeze immediately.
- Fixed: the barrier's "ready"/"refused" messages were never forwarded to the session code, so every barrier
  timed out with "Your partner did not respond". New routing test: fails if any session message type isn't
  forwarded by the main script.

## 0.11.0-preview

- **Cutscenes start together.** Whichever game triggers a cutscene, both games hold it and show "Waiting for
  all players..." at the top left. The partner gets ready: it is moved next to the host if its own game didn't
  trigger the scene, or reports that it's in another area. Then the host sends "go" and both start at once
  (the gap is one network hop).
  - The game's own callbacks and caller name are kept for every held cutscene.
  - If the partner doesn't answer within 15 s, the host goes alone.
  - If the host is in another area or another cutscene, the partner is told immediately and plays its scene
    alone instead of waiting.
  - Skipping still needs both players.
- Cutscenes in different areas aren't synced yet: that needs moving a player into the other area first.
- Fixed earlier tonight: cutscene sync failed before the player existed (New Game opening), and a partner
  joining a host cutscene in progress could get stuck in a loading loop.

## 0.10.0-preview

- **Co-op is now in the game's own title menu.** A "Co-op" entry sits below Main Story. Choosing it turns the
  menu into a co-op lobby built from the game's own rows, with its font, animation, controller and mouse input:
  - Host Co-op Session, which also opens Steam's invite dialog.
  - Join a friend's session (friends who are hosting are listed).
  - Invite Friend, Ready, Start Game, Leave Session and Back.
  - Your partner's name and ready state.
  - Each row's description and status messages use the game's description line at the bottom.
- Start Game returns to the main menu and opens Main Story, where the host picks New Game, Continue or
  Load Game (the game's own save list). The partner's game follows, as before.
- The co-op overlay window no longer opens by itself on the title screen. F6 still opens it, and it is
  shown automatically if the menu integration fails.
- Partner avatars aren't shown yet: the game's UI can only display texture files, and Steam avatars arrive
  as raw pixels.
- **Fixed: the partner got a black screen with no audio at cutscenes.** Reading the host's cutscene timelines
  could fail ("get_size is not callable") around scene changes. That failure also stopped the host's "start"
  message, so the partner's held cutscene never played. Timeline positions are now optional, and a failure
  can't block the message.
- **New safety net:** if the host doesn't confirm a cutscene the partner's game wants to play within 10 s (or
  the connection drops), the partner plays it locally with the game's own callbacks, instead of waiting
  forever. A late host start doesn't replay it.
- Fixed in the menu: Co-op opened Options on a real click or key press; Ready/Invite froze the lobby; Start Game
  didn't open Main Story; and the Main Story submenu's Load Game was renamed to Co-op.

## 0.9.0-preview

- **First-person animation runs natively on the partner.** The game's extra first-person animation files
  (dynamic motion banks) are now set up on the partner model, so it no longer falls back to streaming every bone.
  In a local mirror test the mod's Lua time per frame went from 0.57 ms to 0.31 ms, and a live first-person
  pose packet went from 491 bytes (bone fallback) to 91 bytes.
- **Fixed: long animations on the partner restarted ~30 times a second.** Static layer settings were re-applied
  on every update, which reset the motion. They are now applied only when they change.
- **Fixed: the smaller v2 state header from 0.8.2 was never switched on between two PCs.** The capability
  message wasn't routed. It only worked in the local echo test.
- The co-op window shows the mod version and warns when the partner runs a different release.
- The network plugin writes its status file only when the status changes (plus a 1 s heartbeat), instead of
  4 times a second. It checks for UI commands 10 times a second instead of every frame.

## 0.8.2-preview

- Performance pass: animation descriptors, outfit/equipment scans and door/lock sync cache their engine
  handles. Mod Lua time per frame went from about 1.0 ms to 0.57 ms in an A/B test, and the once-a-second
  frame spikes are gone.
- The partner's backpack is driven natively by the engine instead of copying 90 joints in Lua.
- Negotiated, lossless v2 state header (cached native packet 84 → 70 bytes).

## 0.8.0-preview

- Host-led cutscenes with two-player skip voting, an ordered mission event journal with progress repair,
  and native partner torch lights.

## 0.7.x-preview

- Native animation (motion IDs and frames instead of bones), a matching costume and hair on the partner,
  compact and sparse packet formats, and a mirrored equipment backpack.
