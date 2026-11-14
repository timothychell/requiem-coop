# Debugging a live session

- Host requests the partner's read-only report: bridge `coopnet.send_event("dbgreq:1")` → wait for
  `<game>\reframework\data\coop_partner_debug.json` (partner must tick "allow debug requests").
- Host state: `_G.__requiem_coop_debug()`, session object `_G.__requiem_coop_session_live`
  (`S.E` = engine adapter: `play/freeze/unfreeze/skip/playing/current_id`), menu
  `_G.__requiem_coop_title_menu.menu`, internals `_G.__requiem_coop_internals`.
- `coop_net_log.txt` only logs events **received** from the partner and UI commands — not what we send.
- Screenshot: `./tools/Capture-GameWindow.ps1 -OutputPath <scratch png>` then view it.
- Ask for the partner's debug info **immediately** when something breaks; reports show only current state.
- In a DEBUG build you can also reach the partner directly — see [remote-control.md](remote-control.md).
