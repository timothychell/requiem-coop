# Protocol rules

- Every new optimisation/feature on the wire is **negotiated** (capability event, e.g. `anstate:2`,
  session3 `barrier=1`); older peers keep the old format.
- **Every new event kind must be added to the main script's router** (`handle_event`; session kinds in the
  `if session and (k=="..." ...)` list). `tools/test_routing.lua` enforces this — it broke real sessions twice.
- Session tests (`test_session_sync.lua`) call the library directly with a simulated engine; they do **not**
  cover main-script routing or real engine timing. Add an in-game check for anything engine-facing.

See also the deeper audits in `tools/PROTOCOL_AUDIT.md` and `tools/SESSION_SYNC.md`.
