# Session sync validation: 0.8.0-preview

The previous cinematic play hook requested a Nullable callback overload. The
running build uses EventHandler delegates, so that hook did not resolve. Its
skip gate also depended on a peer acknowledgement that the play path did not
provide. Seven reflected hooks now cover playback, mediator/process skip,
skip requests, and native start/finish notifications. All seven resolved in
the running build; all 18 mission call hooks resolved as well.

The new session library separates decisions from engine calls. The host owns
cinematic instances and skip commits. Clients defer autonomous starts, retain
their native callbacks, and request the host's start. Native assets still play
locally. Available matching timelines receive coarse drift corrections; this
does not establish frame-perfect synchronization of the cinematic subsystem.
Gameplay puppets are hidden and enemy overrides released during cinematics.

Mission events use an ordered host journal, request deduplication, and replay
of gaps. Heartbeats detect a missing final event. Registered mission progress
is reconciled periodically through requestChangeProgressiveNumber, rather than
only writing counters. Unknown flow IDs remain queued and another chapter is
never advanced from a snapshot. This does not cover all game scripting or all
37 save managers. Live read-only inspection found 637 registered counters.

Torches replicate the native FlashLightController's active spot/point lights,
including lighter point lights where that controller exposes them. Two lights
take 110 bytes per snapshot at 10 Hz before transport overhead. Off transitions
also use the reliable channel; 0.6 seconds without data disables remote lights.
This copies basic lighting, not cookies, volumetric shafts, flame or sound.

`test_session_sync.lua` passed 150 assertions in the game's Lua runtime. Cases
include host/client starts, deferred callbacks, one-sided and early skip votes,
non-skippable playback, natural completion, unrelated scene acknowledgements,
stale state, ordered/duplicate/missing mission events, snapshot repair, and
light packet truncation/reordering/stream isolation. Results are saved in
`session-sync-results.json`.

`test_native_torch.lua` created temporary engine SpotLight and PointLight
objects from received snapshots. Both were enabled with the expected range
and intensity (20 m / 1000 and 2 m / 10). Cleanup succeeded. The local player's
torch was off, so active source-beam capture was not verified. See
`native-torch-results.json`. Tests did not start a real cinematic, change real
mission progress, load a save, or interrupt a peer session.

Still required: two PCs on the same preview, actual torch on/off and aim,
mission triggers from either player, natural cinematic completion and both
orders of skip voting. Check transitions into another area and scripted
cinematics that do not use the main mediator. No successful two-PC result is
claimed by these local tests.

The runtime archive must include the new
`reframework/autorun/require/requiem_coop_session.lua` alongside the main Lua
file and existing DLL. Both players must update together.
