# ocahub: cross-agent messaging

`ocac` talks to the `ocahub` broker (a systemd user service). Installed on
dynhetz for now; if `ocac ping` fails there, the hub is not running. JSON
in, JSON out: every command prints one JSON object per event on stdout,
diagnostics to stderr. Exit codes: 0 ok, 1 hub unreachable, 2 timed out
waiting, 3 hub error.

Identity is `name` plus `session` (a session id). Set `OCAHUB_SESSION` once
per agent session and pass `--name`; the hub addresses you as `name@session`.
Sessions also carry their `cwd` (the directory they started in) and can be
targeted by it. One listener per session: the latest registration owns the
socket.

Inside opencode, prefer the MCP tools over raw `ocac`: `agents_list`,
`agent_send`, `agent_reply`, `agent_inbox`. The mapping is below.

Message kinds (send carries one):

- `tell` - fire and forget.
- `ask` - the target owes a reply before it ends its turn. The hub tracks
  open asks; `who` and the inbox show them. An `ask` with `--wait` blocks
  until the reply arrives - the honest way to ask a question.
- `reply` - answers an ask by id (`--reply-to ID`). Forgiving: when no
  live ask matches, the hub passes it through as a plain `tell`.

Commands:

- `ocac ping` - hub reachable?
- `ocac who` - registered sessions (name, session, online, caps, cwd, asks).
- `ocac hello --name explore [--caps a,b]` - register; drains your mailbox.
- `ocac send --to NAME[@SESSION] [-m TEXT] [--kind K] [--wait [SECS]]` -
  send. Without `--wait`, `ask` still records the obligation. `--wait`
  blocks for the reply (default 30s) and prints it.
- `ocac send --cwd PATH [...]` - target the most recent online session
  whose cwd matches (substring, either way). Online only: no mailbox for
  cwd-addressed sends.
- `ocac broadcast [--topic T] [-m TEXT]` - fan out to topic subscribers.
- `ocac sub [--topic PREFIX]` - stream broadcasts and hub events (Ctrl-C
  ends). Hub events use the `ocahub/` topic namespace, e.g.
  `ocahub/session.up`.
- `ocac poll [--name N --session S] [--wait [SECS]]` - drain your mailbox;
  with name/session it also attaches (creating the session if new).
- `ocac bye --name N` - unregister.

MCP tool mapping:

- `agents_list(cwd=?)` - `ocac who`, filtered by directory.
- `agent_send(to|cwd, message, kind, wait, timeout)` - `ocac send`; with
  kind=ask and wait=true it returns the reply itself.
- `agent_reply(reply_to, message, to=?)` - `ocac send --kind reply`.
- `agent_inbox(wait=?)` - `ocac poll` plus the asks you still owe, with a
  reminder. Call it at session start, after long sub-agent work, and
  before ending your turn while any ask is open.

Semantics:

- Online send is at-most-once. Offline targets queue in the hub (SQLite,
  kept 7 days) and arrive on the target's next `hello` or `poll`. An
  unnamed target (`--to NAME`) queues for the next session with that name;
  `--to NAME@SESSION` queues for that session only.
- Deliveries carry `from` (hub-stamped, cannot be forged), `kind`, `id`,
  `reply_to`, `ts`. Reply with `--reply-to ID`.
- `sub` misses anything published before its subscription lands (slow
  joiner). Tolerate gaps, or poll instead.
- A hub restart wipes registration but not the mailbox. Agents must
  re-hello after any disconnect; treat `ocac who` as the source of truth.
