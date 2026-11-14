# Native animation investigation

These development tools use the dev-only bridge `tools/dev/requiem_bridge.lua`
(copy it into `reframework/autorun`, enable it in the REFramework UI, and never ship it).
`Run-Tests.ps1` runs all regression suites; see the main README. Result files the scripts
write here (`*.json`, `*.png`) are local and git-ignored, because they can contain Steam names/IDs.
The notes below are the development log of earlier previews. The animation probe does not change the installed co-op script, network
protocol, saves, or player animation. The test object has a skeleton and Motion component, but
no visible mesh or AI.

From the source root, with a playable scene loaded and the bridge enabled:

```powershell
./tools/Invoke-AnimationProbe.ps1 -Action start
./tools/Invoke-AnimationProbe.ps1 -Action sample
./tools/Invoke-AnimationProbe.ps1 -Action cleanup
```

Always clean up after a test, including after an error. Starting again also
removes the previous test object. A bridge timeout does not cancel a queued
command: send `cleanup` once the game is responding again.

## Observed on 2026-11-13

At takeover, source and installed Lua were identical 0.6.2 files (SHA-256
`2E726268DF034A2ACF7810CFEBF20AA038C21856035757821421EA84658172E6`).
No animation-state rewrite was present in either file.

In chapter `Chap3_10`, on `cp_A000`, a separate skeleton using the player's
static MotionBankAsset and a new TreeLayer played bank 0 / motion 7007.
An initial sample had frame/end frame 0 (resource setup was not immediate).
After 6.041 seconds, frame/end frame were 238/238, with 84 joints and a maximum
quaternion difference metric of 0.37645. Both frame and pose changed without
copying any joint transforms. Cleanup succeeded.

That initial test established multi-frame playback on an isolated skeleton with locally
available resources. On its own it did not establish rendered puppet playback,
cross-character resource loading, upper-body blends, remote playback, cloth,
IK, or combat effects.

The player reported three dynamic-bank slots. Both getDynamicMotionBank and
the wrapped container's get_Item returned nil for all three in this scene.
This may mean empty slots; it does not prove a binding problem. Do not assume
successful calls mean a bank has been transferred, or claim all animations can
be played based on the static-bank test.

## Implemented in 0.7.0-preview

- Animation snapshots for player/enemy layers, including IDs, masks, weights,
  speeds, wrap mode and phase. Blend trees with more than one node and dynamic
  motions retain bone fallback.
- Reliable resource descriptors, capability negotiation and expiring receiver
  acknowledgements. Bone payloads remain until resources are acknowledged.
- Native playback using the sender's resource paths, with phase corrections.
- Enemy timestamps, out-of-order rejection, bounded velocity prediction and
  teleport rejection. Prior-session enemy state is cleared on peer changes.
- Native-animation switch and animation-mode status in the co-op panel.

Local dressed-puppet playback and the DLL echo path both reported native mode,
no bone payload and no animation error. A live three-layer player packet was
201 bytes versus 756 bytes for the 84-joint fallback. Switching native animation
off restored a 756-byte bone packet and a functioning puppet.

Protocol regression checks can run in the bridge without game-object changes:

```powershell
$source = Get-Content mod/reframework/autorun/requiem_coop.lua -Raw
$tests = Get-Content tools/test_animation_protocol.lua -Raw
if ($source.Contains(']====]')) { throw 'Lua delimiter collision' }
$code = 'local protocol_source = [====[' + $source + "]====]`n" + $tests
./tools/Invoke-CoopBridge.ps1 -Code $code | ConvertTo-Json -Depth 8
```

The bridge uses the game's exact Lua runtime. Passing source text avoids the
game's restriction on absolute paths in `io.open`. The generic bridge runner
executes supplied Lua; use it for deliberate development commands only.

## 0.7.1-preview: appearance and compact packets

The sender now announces its complete costume recipe: root skeleton, mesh and
material resource paths, all 256 submesh flags per part, and strand-hair assets
and rendering settings. These travel reliably on changes, with a periodic
refresh, rather than being repeated in each state packet. Submesh masks use
bitsets; the tested appearance recipe is 3,044 bytes.

The root skeleton is assigned before montage creation. Free GPU cloth and its
wrapper are disabled on the puppet while the actual jacket mesh remains
visible. Disabling a chain wrapper had also disabled some body-part updates;
those updates are restored. Initial montage DrawSelf=false is treated as a
loading state for costume meshes/strands, rather than permanent invisibility.
Grip and shadow helpers retain their own visibility.

The broken hair case had matching resource paths but uninitialized GPU strand
simulation (0 strands, versus the player's 200). Explicit binding/reset and
normal body/hair updates initialize it correctly. Hair settings, including
color, width, roughness and LOD configuration, are copied from the sender.

`validate_model.lua` compares the live player and puppet without changing them.
The current local comparison passed 2,392 checks with no failures in native
mode and in bone fallback: nine meshes/materials, their complete submesh masks,
hair resources/settings, simulation initialization/count and valid render bounds.
See `model-validation-results.json`, `model-bone-fallback-results.json` and
`model-after.png`. This validates the current Leon costume locally, not all
characters/costumes or two-PC behavior.

AN02 registers static layer definitions reliably, waits for an acknowledgement,
then sends a definition hash and float32 phase. Default speed/weight values are
omitted; other values retain float32 precision. No extra quantization is used.
Missing definitions are requested again with rate limiting. AN01 remains the
fallback until definitions are acknowledged or when talking to older previews.
The regression suite passed 587 checks. Its two-layer state is 95 bytes versus
157 for AN01; a live three-layer DLL echo state was 96 bytes versus 201 in AN01.
These are payload sizes, excluding reliable setup and transport overhead.

To compare a dressed mirror/echo puppet:

```powershell
./tools/Invoke-CoopBridge.ps1 -Code (Get-Content tools/validate_model.lua -Raw) |
    ConvertTo-Json -Depth 12
./tools/Capture-GameWindow.ps1
```

The capture helper uses the game window, without moving the camera or changing
the player's character. Local tests are restored to normal idle mode afterward.

## Remaining work

The 0.7.2 serialization audit and its latest results are documented in
`PROTOCOL_AUDIT.md`; the earlier byte counts above describe 0.7.1.

1. Test different player characters and enemy playback on two PCs. Resource
   paths are transmitted; cross-character rendering has not been verified.
2. Implement full blend-tree and dynamic-motion replication, plus component
   play-speed/root-motion settings, to remove more of the bone fallback.
3. Profile and optimize capture; the local native capture cost was higher than
   the old path. Do not describe payload savings as a measured CPU improvement.
4. Verify movement authority and attacks against the non-owner.
   Enemy authority currently follows proximity; moving it entirely to the host
   also needs a verified way for enemies to target and attack the joining player.
5. Verify rendering, transitions, weapon attachment, cloth and disconnect/scene
   cleanup, then measure bandwidth and smoothing with two PCs. Native playback
   does not establish full remote cloth physics or weapon-specific constraints.

The 0.6.2 archives and a pre-change source backup remain available for rollback.
