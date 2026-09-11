# ocahub: cross-agent messaging

`ocac` talks to the `ocahub` broker (a systemd user service). Installed on
dynhetz for now; if `ocac ping` fails there, the hub is not running. JSON
in, JSON out: every command prints one JSON object per event on stdout,
diagnostics to stderr. Exit codes: 0 ok, 1 hub unreachable, 2 timed out
waiting, 3 hub error.

Identity is `name` plus `session` (a session id). Set `OCAHUB_SESSION` once
per agent session and pass `--name`; the hub addresses you as `name@session`.
One listener per session: the latest registration owns the socket.

Commands:

- `ocac ping` - hub reachable?
- `ocac who` - registered sessions (name, session, online, caps).
- `ocac hello --name explore [--caps a,b]` - register; drains your mailbox.
- `ocac send --to NAME[@SESSION] [-m TEXT] [--wait [SECS]]` - send. `--wait`
  blocks for the reply (default 30s) and prints it. The peer replies with
  `ocac send --reply-to ID -m ...` and no `--to`; the hub routes it back
  through the pending table, so no addressing is needed.
- `ocac broadcast [--topic T] [-m TEXT]` - fan out to topic subscribers.
- `ocac sub [--topic PREFIX]` - stream broadcasts and hub events (Ctrl-C
  ends). Hub events use the `ocahub/` topic namespace, e.g.
  `ocahub/session.up`.
- `ocac poll [--name N --session S] [--wait [SECS]]` - drain your mailbox;
  `--wait` blocks for one message (default 30s).
- `ocac bye --name N` - unregister.

Semantics:

- Online send is at-most-once. Offline targets queue in the hub (SQLite,
  kept 7 days) and arrive on the target's next `hello` or `poll`. An
  unnamed target (`--to NAME`) queues for the next session with that name;
  `--to NAME@SESSION` queues for that session only.
- Deliveries carry `from` (hub-stamped, cannot be forged), `id`,
  `reply_to`, `ts`. Reply with `--reply-to ID`.
- `sub` misses anything published before its subscription lands (slow
  joiner). Tolerate gaps, or poll instead.
- A hub restart wipes registration but not the mailbox. Agents must
  re-hello after any disconnect; treat `ocac who` as the source of truth.
