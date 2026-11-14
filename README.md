# Requiem Co-op

An experimental two-player co-op mod for **Resident Evil Requiem** (PC, Steam), built on
[REFramework](https://github.com/praydog/REFramework).

Each player runs their own copy of the game. Your partner appears in your world as a fully animated
character that mirrors their real movement, and you appear in theirs. Sessions run through Steam:
invite a friend, both tick **Ready**, and when the host starts a New Game or loads a save, the partner's
game follows automatically.

> **Status: 0.12.0-preview, experimental.** Expect bugs, and back up your saves. Movement, animation,
> costumes, shared items/doors, shared enemies and save handoff work. Combat effects (muzzle flashes,
> blood, sounds), grabs/finishers, breakable boxes and full cloth physics aren't synced yet. Host-led
> cutscenes, mission sync and partner torches are implemented but still need more two-PC testing.
> See [Known limitations](#known-limitations).

Unofficial fan project. Not affiliated with or endorsed by Capcom. No game files are included or distributed.

## Features

- **Partner puppet:** your partner is rendered with their real character model, full-body animation
  (~30 updates/s, snapshot interpolation) and a name tag. They only appear when you're both in the same area.
- **Native animation:** your partner's animation runs on the game's own animation system, using motion IDs
  and frames, including first-person animation banks. Every bone is streamed only as a fallback, for blend trees and
  other states that can't be described this way.
- **Matching costume and hair:** costume meshes/materials, submesh masks, strand hair and equipment such as
  the backpack match the sender.
- **Native co-op menu:** a Co-op entry in the game's title menu opens a lobby built from the game's own menu
  rows: host, join friends, invite, ready up, start and leave, with controller and mouse support.
- **Steam sessions:** friends-only lobby, invites via the Steam overlay, peer-to-peer over Steam networking.
  No port forwarding, no IP addresses. Direct IP (UDP) is available as a fallback.
- **Ready-up:** in a session, the title screen's New Game / Continue / Load Game only go through once both
  players are ready. The host drives; the partner's game follows:
  - **New Game:** the partner starts a new game on the same difficulty at the same time.
  - **Continue / Load Game:** the partner loads the host's save.
- **Join a host who's already playing:** the host's current state is saved and sent to the partner.
- **Shared world:** an item picked up by one player disappears for the other (inventories stay separate).
  Unlocked locks/doors stay unlocked for both, and doors swing for both players. Changes in areas the
  other player hasn't reached yet are applied when they get there.
- **Shared enemies (experimental):** each enemy is run by the game of the player it's closest to, and the other
  game mirrors it, so you both see the same zombie chasing whoever it's after. Damage from either player counts.
- **Shared story progress:** story counters, area flow, puzzle flags, objectives, lights, documents and
  watched cutscenes go through an ordered host event journal. Missing events are replayed, and mission
  counters are periodically repaired against the host.
- **Cutscenes together:** whoever triggers a cutscene, it starts on both PCs and freezes on its first frame
  ("Waiting for all players..."). When both copies are frozen, they unfreeze at the same moment (the host compensates
  for network delay). The game's own cutscene call is never blocked. Skipping needs **both** players to vote.
  A player in another area doesn't block the other (cross-area cutscenes aren't supported yet).
- **Reloads, game over and pause together:** the host's reloads bring both players back into the same save,
  a death or mission failure ends the game for both, and pausing pauses the partner too.
- **Held weapons and torches:** drawn weapon meshes and flashlight/lighter lights are recreated on the puppet.
- **Automatic smoothing:** the playback buffer adapts to the measured connection quality.

## Installation

**Both players** do every step. You need:
- Resident Evil Requiem on **Steam** (PC). Both players must be on the **same game version**: let Steam update before playing.
- The **same release of this mod** on both PCs. The co-op window warns you when they differ.

### 1. Find your game folder

In Steam, right-click **Resident Evil Requiem** > **Manage** > **Browse local files**. The folder that opens
(the one containing `re9.exe`) is your **game folder**. It's usually something like:

```
C:\Program Files (x86)\Steam\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem\
```

### 2. Install REFramework

1. Go to the [REFramework nightly builds](https://github.com/praydog/REFramework-nightly/releases/latest)
   and download **`REFramework.zip`** (not `VR.zip` or `csharp-api.zip`). Requiem is new enough that you need
   a nightly build rather than an older stable release.
2. Open the zip and copy **`dinput8.dll`** into your game folder, next to `re9.exe`.
3. Start the game once. If REFramework is working, a REFramework menu appears (press **Insert** to show/hide it)
   and a `reframework` folder is created in the game folder. Then close the game.

Skip this step if you already use REFramework.

### 3. Install Requiem Co-op

1. Download `RequiemCoop-<version>.zip` from this repository's **Releases** page.
2. Extract it **into your game folder**. When asked, let it merge into the existing `reframework` folder.
3. Check that these four files now exist:
   ```
   <game folder>\reframework\autorun\requiem_coop.lua
   <game folder>\reframework\autorun\require\requiem_coop_session.lua
   <game folder>\reframework\autorun\require\requiem_coop_menu.lua
   <game folder>\reframework\plugins\requiem_coop_net.dll
   ```
   (If you ended up with `reframework\reframework\...`, you extracted one level too deep: move the
   `autorun` and `plugins` folders up into `<game folder>\reframework\`.)

### 4. Check it works

Start the game. The title menu now has a **Co-op** entry below Main Story. **F6** opens the co-op overlay window,
which shows **"Signed in as: <your Steam name>"**.

If it says *Network plugin not running*, `requiem_coop_net.dll` is in the wrong place or REFramework isn't installed.

### 5. Back up your saves (recommended)

The mod never deletes saves, but it is experimental. Copy this folder somewhere safe:

```
C:\Program Files (x86)\Steam\userdata\<your Steam ID number>\3764200\remote\win64_save\
```

### Updating / uninstalling

- **Update:** close the game, then extract the new zip over the old files. Both players update together.
- **Uninstall:** delete `reframework\autorun\requiem_coop.lua`, the two `requiem_coop_*.lua` files in `reframework\autorun\require\`
  and `reframework\plugins\requiem_coop_net.dll`. Optionally also delete the `coop_*` files in
  `reframework\data\`. Delete `dinput8.dll` to remove REFramework entirely.

## Play

Everything happens in the game's own title menu, which has a new **Co-op** entry below Main Story.

1. **Host:** choose **Co-op** > **Host Co-op Session**. Steam's invite dialog opens; invite your partner.
2. **Partner:** accept the Steam invite, or choose **Co-op** > **Join <host's name>**.
3. **Both:** choose **Ready**. The lobby shows whether your partner is ready.
4. **Host:** choose **Start Game**, then New Game, Continue or Load Game. The partner's game follows by itself.

Host already playing? The partner chooses **Co-op** > **Join Host's Game in Progress**.
The overlay window (**F6**) has the same controls, plus Direct IP, the solo tests and options.

Loading a save needs the partner to have **at least one save of their own**, because the game's Continue
button is used to start the load. New Game works without any saves.

## What happens to the partner's saves

Requiem save files are tied to the Steam account and to their slot number. To load the host's save, the
partner's game:

1. backs up its own file in the slot the host loaded from (`<slot>.coopbak`),
2. puts the host's file in that slot and uses the host's Steam ID as the decryption key for that one load,
3. puts its own key and file back as soon as the game has loaded.

If the game crashes mid-load, the original file is restored the next time the game starts
(see `reframework\data\coop_restore.json`). The partner's other saves are never touched. That said, this is
experimental: **back up your saves** before trying it.

## Testing on your own

- **Solo network test (echo):** your own movement goes out through the network code and comes back.
  The puppet stands 1.5 m to your side. "Test save transfer (echo)" checks the save transfer.
- Options > **Mirror test:** the puppet copies you with no networking at all.

## Troubleshooting

Logs are in `reframework\data\`: `coop_net_log.txt` (network plugin) and `coop_link.json` (status).

| Message | Meaning |
|---|---|
| *Network plugin not running* (also shown in the Co-op menu) | `requiem_coop_net.dll` isn't in `reframework\plugins`, or REFramework is missing. |
| *partner has a different mod version* / *Partner mod version: ...* | Both players need the same release. |
| *partner is in another area* | You're in different chapters/maps. |
| *Couldn't start loading* | The partner has no saves of their own yet. Play to the first save point once. |

**Debug reports:** if the partner ticks Options > **Let the host request debug info from me**, the host can click
**Get partner's debug info** to receive a read-only status snapshot of the partner's game in
`reframework\data\coop_partner_debug.json`. It is off by default and never runs anything on the partner's game.

When reporting a bug, please include both players' `coop_net_log.txt`, the mod version and what you were doing.

## Performance

Measured on one PC with the mirror-test puppet (partner model and full send/receive path, no network),
averaged over 300 frames per stage:

| | 0.8.1 | 0.8.2 | 0.9.0 |
|---|---:|---:|---:|
| Mod Lua time per frame | ~1.03 ms | ~0.57 ms | **~0.31 ms** |
| First-person pose packet (live 3-layer state) | ~491 bytes (bone fallback) | ~491 bytes (bone fallback) | **91 bytes** (native) |

Expensive engine reads (animation descriptors, outfit masks, equipment) are cached or spread out so they
don't cause once-a-second frame spikes. See [`tools/PERFORMANCE_AUDIT.md`](tools/PERFORMANCE_AUDIT.md).

## Known limitations

- **Two-PC coverage is limited.** Most automated checks run on one PC (mirror/echo). Cutscene sync, mission
  repair, torches and enemy authority handoff need more real sessions. Bug reports are very welcome.
- Combat effects (muzzle flashes, blood, sounds), grabs/finishers and breakable boxes aren't synced.
- Free cloth/chain physics is disabled on the puppet (the jacket is still rendered).
- Enemies are run by the closest player's game; attacks against the non-owner are not fully verified.
- Area transitions don't happen together; each player moves on their own.
- Only Steam PC builds are supported, and both players need the same game version.

## How it works

- **Lua script** (`mod/reframework/autorun/requiem_coop.lua`), running in REFramework's Lua environment:
  - Builds the partner puppet: an empty `via.GameObject` dressed with the game's own character parts via
    `app.CharacterManager.requestInstantiateMontage`, with the sender's skeleton set through a `via.motion.DummySkeleton`.
  - Captures the animation layers (motion bank/ID, frame, speed, weight, masks) and announces the animation
    resources reliably. That includes the main motion bank, the skeleton and any dynamic (first-person) motion
    banks. The receiver sets them up and acknowledges before the sender stops sending bones. Unsupported
    states (blend trees, dynamic motions) fall back to compact bone rotations.
  - Handles ready-up, the title-screen gate and the save handoff by hooking `app.TitleFlowController`,
    `app.SaveServiceManager` and `app.SaveEncryptionOperatorApp`.
- **Session library** (`mod/reframework/autorun/require/requiem_coop_session.lua`): host cinematic decisions,
  skip votes, ordered mission events, progress reconciliation and remote lights.
- **Title menu** (`mod/reframework/autorun/require/requiem_coop_menu.lua`): hooks the game's title menu
  (`app.UI1010GuiBehavior.updateItems` / `onSelectItemDecided` / `onSelectItemCanceled`). It inserts a Co-op row,
  swaps in lobby rows on demand and relabels them. GUI writes must happen in the game's update phase.
- **Network plugin** (`plugin/requiem_coop_net.cpp`), a REFramework plugin DLL:
  - Steam lobbies, invites and `ISteamNetworkingMessages` P2P through the game's own `steam_api64.dll`
    (flat API, no Steamworks SDK needed), a direct UDP fallback, and chunked reliable save transfer.
  - Runs on the game thread via REFramework's `on_pre_application_entry` callback. A plugin must not run
    its own worker thread, because REFramework suspends all threads while installing hooks.
  - Registers a `coopnet` table in REFramework's Lua state (`send_state`, `send_enemy`, `send_event`, `poll`),
    so poses and events never touch the disk. Rare UI commands and status use `coop_cmd.json` / `coop_link.json`.
- **Protocol:** each optimisation is negotiated with the peer (compact layers, cached headers, sparse bones,
  enemy batching, v2 state header, dynamic banks), so a newer build talking to an older one falls back
  to formats both understand. See [`tools/PROTOCOL_AUDIT.md`](tools/PROTOCOL_AUDIT.md).

## Building from source

Requires Visual Studio 2022 (or the Build Tools) with the **Desktop development with C++** workload.

```powershell
plugin\build.bat                                   # -> plugin\build\requiem_coop_net.dll
powershell -ExecutionPolicy Bypass -File package.ps1 -Version 0.9.0-preview   # -> dist\RequiemCoop-<version>.zip
```

GitHub Actions builds every push. Pushing a tag such as `v0.9.0-preview` publishes a release with the zip attached.

## Contributing / development

The regression suites run inside the game, in its exact Lua runtime, through a development-only bridge:

1. Copy `tools/dev/requiem_bridge.lua` into `<game folder>\reframework\autorun\`. **Never ship it**: while it
   is enabled, any program that can write to `reframework\data` can run Lua in your game.
2. Start the game, load into gameplay and enable it under Script Generated UI > **Requiem Bridge**.
3. From the repository root run `./tools/Run-Tests.ps1`. The game folder is found through Steam;
   override it with `-GameRoot` or `REQUIEM_GAME_ROOT`.

The suites cover player/enemy packets (round trips, truncation, random byte mutations), compact/v2 headers,
dynamic-bank descriptors and a two-endpoint session simulation; they don't change game objects or saves.
`tools/README.md` describes the probes and validation scripts. Before a release, please also test with two PCs.

The main Lua file is close to Lua's limit of 200 local variables per chunk: put new state in existing
tables (e.g. `anim.*`, `visual.*`, `world.*`) instead of new top-level locals.

## Credits

- [REFramework](https://github.com/praydog/REFramework) by praydog: modding framework and plugin API
  (`plugin/include/reframework/API.h`, MIT licence, see `THIRD_PARTY_NOTICES.md`).
- [Lua](https://www.lua.org/) 5.4.3 (MIT licence): the plugin compiles REFramework's bundled Lua sources so it can
  talk to the Lua script in memory.

## License

MIT. See [`LICENSE`](LICENSE). Third-party components are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
