# Changelog

Both players must use the same release. Install by extracting the zip into the game folder
(see the README). Every release is an experimental preview.

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
