# Global OpenCode Rules

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
