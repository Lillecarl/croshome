# Global OpenCode Rules

## The question tool

`question`. It puts multiple-choice questions to me and blocks until I answer.
Each option carries a `label` (1-5 words) and a `description`; `custom` adds a
free-text answer and defaults on, so never write an "Other" option yourself.

This is the tool the workaround rule in **Offer both routes** requires. It is
not `needs_user`, which ends a turn and asks nothing.

The tool only registers when the client is `app`, `cli` or `desktop`, which
covers the TUI. If it is missing, `OPENCODE_ENABLE_QUESTION_TOOL=1` forces it
on.

## Cross-agent messaging

Other agent sessions on this machine can send you messages through the ocahub
broker. Two rules are resident because they bind before you would think to load
anything:

- Call `agent_inbox` at session start, and again before you end a turn.
- **An ask you received is a debt.** Answer it with `agent_reply(reply_to=<id>)`
  before your turn ends. The stop hook holds the session open until you do.

Everything else -- `ocac`, the other MCP tools, message kinds, delivery
semantics -- is in the `ocahub` skill. Load it when you need to send something.

## Version Control

- Load the **jj** skill (`skill({ name: "jj" })`) before any VCS operation and
  go through it. Never call `jj` or `git` directly.
- A `.jj` folder means a jj repo: no git write operations. Read-only git-style
  queries (`git log`, `git diff`) the skill wraps safely.
- **Subagents must not use VCS tools unless the user asked.** log, diff, show,
  blame and annotate load hundreds of lines into the child context and can
  waste that session for everything after. A subagent that believes it needs
  one: confirm with the user, state the context cost, and offer the
  alternative — current file state plus a targeted summary from the primary
  agent.
- The exception is deliberate isolation: a subagent loading the jj skill *to
  keep* history out of the primary context is the good case.

## Task reuse

The Task tool takes a `task_id`. Note it when you create a task; passing it
again sends a new message into that child session, which still holds its
context, tool output and file reads. A fresh task throws all of that away and
re-explores.

Reuse it when the follow-up is on the same topic. Start fresh when the new work
is genuinely unrelated — stale context confuses the model and costs tokens. In
doubt, send the existing session a one-line summary of the new question and let
it say whether it can answer.

## Editing code

- **Never mass-edit with a script**: no `sed`, `awk`, `python -c`, no inline
  rewriting. Every edit goes through the `edit` tool.
- read → edit → read. The verification read is not optional.
- No `edit` tool (some subagents): read the file, then `write` it whole. Still
  never `sed`.
- Whenever the `edit` tool fails you, use **pyedit**: load the
  `pyedit` skill for its instructions (also served over MCP:
  `pyedit mcp`).

## Timeouts

The bash tool's `timeout` is milliseconds, and the lazy default is ten
minutes. A wedged command then costs the whole ten before it reports
anything.

- Default to no explicit timeout, or one near the command's real duration.
  Most commands finish in seconds.
- **Any timeout above 3 minutes (180000) needs a motivation.** One line next
  to the call: why this command needs it — what it waits on, or a measured
  duration. "It might be slow" is not a motivation.
- Work that truly runs for minutes gets no big timeout: run it in the
  background and read the log file. A timeout that fires is a result; get it
  sooner, not later.

## Background work

`pystemctl` owns background processes. Never `setsid`, `nohup`, trailing
`&`, or `sleep`-polling for completion.

- Start: `pystemctl run --tag <name> -- <cmd>` (`--remain-after-exit`
  keeps the exit status; successful units are otherwise collected).
- Wait: `pystemctl wait --tag <name> --timeout <s>` reports the unit's
  exit code. A timeout that fires is a result; investigate, do not re-wait
  longer.
- Read: `pystemctl logs --tag <name>`; live list: `pystemctl jobs`.
- `sleep` waits for clocks (settle delays, rate limits), never for
  processes.

## Working copy hygiene

Check `jj status` through the jj skill before starting new work, and report
what is uncommitted. Commit or shelve it first, so it does not mix into the new
work. Ask for direction; never discard or overwrite it.

## Subagents

| Agent | For | Notes |
| --- | --- | --- |
| `@explore` | library and codebase research | Read-only: reads, searches, fetches docs, modifies nothing. Long-lived — summarises on handoff so the primary context stays small. |
| `@d4fdo` | executing an orchestrator's plan | DeepSeek V4 Flash via OpenCode Zen. Full tools. Executes faithfully without redesigning, then reports what changed and what broke. |
| `@general` | multi-step research and tasks needing tool access | |

Never create a throwaway subagent for a question an existing session can
answer. See **Task reuse** above.
