# Performance and protocol audit (0.8.2 and 0.9.0 previews)

All numbers were measured in the running game (single PC, Grace, 68 joints) through the
debug bridge. `os.clock()` has 1 ms resolution here, so per-call figures are averages
over hundreds of calls/frames. Raw result files (kept locally, not committed): `bench-before.json`, `bench-after.json`,
`perf-ab-results.json`, `perf-ab-final.json`, `perf-pass-test-results.json`.

## Whole-frame A/B (mirror puppet, same scene, two passes each)

| | 0.8.1 | 0.8.2 |
|---|---:|---:|
| Mod Lua time per frame | 1.06 / 1.00 ms | 0.56 / 0.58 ms |
| Frame-time overhead vs mod disabled | +0.86 / +0.96 ms | +0.64 / +0.67 ms |
| p95 frame time | 10.19 / 9.61 ms | 8.62 / 8.76 ms |

The remaining overhead includes rendering a second full character (hair strands etc.),
which is engine/GPU work rather than mod Lua.

## What was slow and why

| Cost | Before | After | Cause / fix |
|---|---:|---:|---|
| `anim.capture` per send (30 Hz) | 0.87–0.91 ms | 0.12 ms | `get_MotionBankAsset` allocates a fresh holder wrapper per call (0.2–0.76 ms). Descriptor now re-read once a second or when layer count/bank type change. Layer settings cached per motion (refreshed every 0.5 s). |
| Model scan | 2.5 ms every 1 s | ~0.7 ms every 3 s | Each costume mesh reports 256 part flags with no bulk getter (2,300 reflected calls). Masks are cached and re-verified on a rolling budget (2 meshes per scan, each ≤ every 3 s). Hair getters resolved once. |
| Equipment scan | 1.4 ms at 2 Hz | 0.7 ms at 2 Hz | Same mask cache, value-only per-object cache (name / has-component), hoisted type lookups. Runs on frames that do not capture a state, so costs never stack. |
| Gimmick sync (connected only) | 0.44 ms every frame | ~0.02 ms | Structure lists, type names and GUID strings were re-resolved for 12 gimmicks per frame. Now resolved once per 2 s gimmick-list lifetime. |
| Puppet backpack | ~90 joints × 4 reflected calls every frame | 0.004–0.008 ms | The real player drives it with `SameJointsConstraint`; the puppet now does the same (child transform + constraint). The Lua copy loop remains as fallback. |
| Bone read/apply | string-dispatched calls | resolved method handles | ~3× faster per call in isolation. |

Caching rules (verified in-game): GameObjects, mesh components, motion layers and gimmick
cores have stable addresses; **resource holders do not** (fresh wrapper per getter call), so
they are never used as cache keys. Caches hold only plain values, except gimmick structure
handles, which live no longer than the gimmick list they came from (same as before).

## Protocol: state v2 header (negotiated with `anstate:2`)

Lossless against v1's wire values; old peers keep receiving v1.

- Time: `os.clock()` is `clock()/1000`, so a u32 of milliseconds reproduces the exact same
  double (v1 sent an 8-byte double). Non-millisecond times fall back to v1.
- Root rotation: when x and z quantise to 0 (upright character), only y and w are sent.
- Header-cached packets drop the empty kind/model/area fields.
- v1 sequence numbers never reach 2^31, so the top bit marks v2.

| Case | v1 | v2 |
|---|---:|---:|
| Cached native, 2 layers + root offset | 84 B | 70 B |
| 600 randomised states (avg) | 242.7 B | 232.2 B |

`tools/test_state_v2.lua`: 184,665 checks — every v2 packet decodes field-for-field identical
to its v1 encoding, plus truncation, 3,600 byte mutations, reserved flags and fallbacks.
Existing suites unchanged at the time: 4,103 protocol, 169,046 fuzz, 158 session checks.

## 0.9.0-preview: dynamic motion banks

First-person scenes previously fell back to bones: the player runs extra *dynamic* motion banks
(`ch0200FPS`, `ch0200L2FPS`; empty slots in between), and active layers use bank IDs from them
(e.g. 900). The animation descriptor now carries an optional fifth field with each dynamic bank's
path, priority, order, overwrite flags, bank ID, bank type and mask bit. The receiver creates matching
`via.motion.DynamicMotionBank` objects before `setupMotionBank`. Peers older than 0.9.0 reject the
five-field descriptor and keep receiving bones, as before. Reading the banks costs ~0.01 ms and happens
with the once-a-second descriptor refresh.

Enabling this exposed an older receiver bug: `changeLocalBankType` (and the other static layer setters)
ran on every snapshot, and `changeLocalBankType` restarts the layer's motion. Long motions reset to
frame ~0 about 30 times a second. Static settings are now applied only when they change. Sampled
afterwards, the puppet follows the source frame continuously, 10 frames behind (the interpolation buffer).

| Mirror puppet, first-person scene | 0.8.2 | 0.9.0 |
|---|---:|---:|
| Animation mode | bones (fallback) | native |
| Mod Lua time per frame | ~0.57 ms | 0.31 ms |
| Frame time vs mod disabled | +0.66 ms | +0.19 ms (7.82 vs 7.57/7.68 ms) |
| `pose_apply` per frame | 0.28 ms | 0.0014 ms |
| Live 3-layer pose packet (all compression on) | 491 B | 91 B |

Also fixed: the `anstate:2` capability was never routed to `anim.event`, so the v2 header from
0.8.2 only switched on in echo mode, never between two PCs.

Plugin file I/O: the status file `coop_link.json` was rewritten 4 times a second. It is now written
only when its content changes, plus a 1 s heartbeat for the Lua liveness check (3 s timeout). The
command-file stat moved from every frame to 10 Hz.

## Remaining

Bone fallback still applies to multi-node blend trees and to nodes that report `get_DynamicMotion`.

Not measured: Steam transport overhead, two-PC network behaviour, and the plugin's file I/O cost on
slow disks. The 0.9.0 plugin changes need a game restart to load, so they have not yet been
measured in-game.
