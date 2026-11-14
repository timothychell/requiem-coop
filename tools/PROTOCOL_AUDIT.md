# Protocol audit — 0.7.2-preview

Audited the Lua serialization and the unchanged v5 DLL transport. Changes were
tested in the game's Lua runtime and through the live DLL echo path.

| Case | Before | After | Evidence |
| --- | ---: | ---: | --- |
| Three native layers | 96 bytes | 81 bytes | Live DLL echo |
| Two-layer regression fixture | 95 bytes | 80 bytes | Codec round trip |
| Captured 84-joint fallback | 756 bytes | 513 bytes | Exact int16 component comparison |
| Later live fallback pose | 756 bytes | 517 bytes | Live DLL echo |
| Twelve 150-byte enemy records | 12 messages | 2 messages | Batching regression fixture |

These counts are Lua payloads, excluding the DLL's four-byte RQ header, Steam/IP
framing, reliable setup, retransmission and encryption. The enemy row is a
fixture, not a measurement from a two-PC session. Actual aggregation depends
on record sizes and range/ownership filtering. These are application-message
counts; Steam's internal framing/coalescing was not measured. Direct UDP maps
each such message to one datagram.

## Changes

- Header templates move skeleton ID, character, model/preset and area into an
  immutable, hashed definition. The sender uses the shortened header only after
  acknowledgement. Every state still includes its sequence, double timestamp,
  absolute float32 position, original int16 root rotation and pose data. Missing
  definitions trigger rate-limited repair; the sender then returns to full
  headers until acknowledged again.
- Sparse bone packets carry a component bitmap and only int16 values that
  differ from `{0, 0, 0, 32767}`. Reconstruction reproduces the previous wire
  values exactly, including negative quaternion signs. Compression is selected
  only when it is smaller. It is independent of any preceding frame.
- Enemy records from the same 10 Hz tick are packed together, capped at 1,150
  payload bytes and 32 records. Single records and oversized records retain
  their original packet format. No buffering across frames is introduced.
- Each feature has its own capability announcement. Old peers receive the old
  wire format. Native AN01/AN02 and model appearance synchronization are retained.

No C++ transport change, new DLL build, animation update-rate reduction or extra
quantization was required. A generic compression stream was not introduced.

## Validation and cost

4,103 regression assertions passed, including legacy compatibility, exact sparse
component recovery, dense-pose fallback, truncations, header acknowledgement and
repair, peer capability reset, batch boundaries and sender/receiver integration.

The read-only model comparison passed 2,392 checks with no failures in native
and sparse-bone echo modes. Matching costume/hair behavior is retained.

On one 200-round-trip local benchmark, the bone codec measured approximately
0.060 ms before and 0.125 ms after these changes. An earlier run measured 0.090
and 0.195 ms. The added cost was roughly 0.065–0.105 ms per encode/decode round
trip, in exchange for the measured payload reduction. These are small local
samples using os.clock, not a frame-time or network-latency guarantee.

Evidence: `animation-protocol-results.json`, `protocol-audit-live-native.json`,
`protocol-audit-live-bones.json`, `protocol-audit-model-native.json` and
`protocol-audit-model-bones.json`. `protocol-audit-pose.json` holds the captured
pose used for the exact before/after comparison.

## Limits and remaining opportunities

- Steam transport overhead, retransmission and WAN behavior need a real two-PC
  trace. The plugin's existing Traffic counters are packet counts, not bytes,
  and do not include all reliable traffic.
- Native packets are already small; packet overhead is increasingly significant.
  Player/enemy multiplexing could reduce it further, but would need another
  framing change and measurement to justify the complexity.
- Full blend-tree/dynamic-motion replication would remove more bone fallback.
  This remains an animation-system task, rather than a serialization change.
- Header fields, timestamps and animation values could be quantized further,
  but that would change precision. This audit intentionally retains the current
  values and timing semantics.
- The C++ source contains MSZIP helper functions, but the current send paths do
  not call them. Save compression was not added or claimed by this audit.
- Steam events use the reliable channel. The UDP fallback sends events as UDP;
  the new header definitions have application-level acknowledgement/retry, but
  this does not make all existing UDP world events reliable.

Two-PC validation is still required before calling this a stable release.
