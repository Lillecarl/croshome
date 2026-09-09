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

## Task Reuse (Critical)
- **Before creating a new task, check if an existing task session already covers this goal.** If one exists, add your follow-up as a message in that session instead of spawning a new one.
- Tasks are expensive to set up. Reusing an existing task session preserves all accumulated context and avoids redundant exploration.
- If you are unsure whether a prior task is still relevant, summarize your new question and ask the existing task session first — it will tell you if it can answer or needs fresh context.

### How to reuse a task session
The Task tool has a `task_id` parameter. When you create a task, note its `task_id` from the output. For follow-up work on the same topic, call the Task tool again with the same `task_id` — this sends a new message into the existing child session instead of spinning up a fresh one. The child retains all prior context, tool outputs, and file reads.

Example: after spawning `@explore` with a research goal, the result includes a `task_id`. If you need to drill deeper, reuse that `task_id` rather than creating a new `@explore` session. This is how you "keep feeding it follow-up questions."

### When NOT to reuse
Do NOT reuse a task session when the new work is on a genuinely different topic — the old session's context will confuse the model and waste tokens. When in doubt, ask the existing session first: send it a brief summary of the new question and let it tell you if it can answer or if you should start fresh.

## Editing Code (Critical)
- **NEVER fix or refactor code using scripts** (e.g. `sed`, `awk`, `python -c`, or any inline script that mass-edits files). Every edit must go through the dedicated `edit` tool.
- **Always follow read -> edit -> read pattern.** First read the file to understand its full context, then make targeted edits, then read the result to verify correctness. Do not skip the verification read unless explicitly told otherwise.
- If the `edit` tool is not available (e.g. subagents without edit access), use `write` to rewrite the entire file after reading it — never use `sed` or similar to patch files.

## Working Copy Hygiene
- **Before starting any new work, verify the working copy is clean.** The agent should check status (`jj status` via the jj skill) and report any uncommitted changes.
- If there are uncommitted changes: **commit or shelve them first** before beginning new work, so context is preserved and new changes don't get mixed in.
- Ask the user for direction rather than discarding or overwriting uncommitted work.

## Explore Agent
An **explore** subagent is available via `@explore`. This agent is for library/codebase research:
- **Read-only** — it can read files, search code, fetch docs, but must not modify anything.
- **Long-lived** — once spawned, it persists as a child session. Keep feeding it follow-up questions rather than creating a new @explore each time.
- **Summarizes on handoff** — when returning control to the primary agent, it should provide a concise summary of findings so the primary context doesn't bloat.

### Usage Pattern
1. Primary agent hits an unknown library or codebase area.
2. Primary agent invokes `@explore` with a clear research goal.
3. Explore agent researches, summarizes, and stays alive in its child session.
4. Primary agent (or other agents) asks follow-ups **in the same child session**.
5. Only spawn a **new** @explore if the topic is genuinely unrelated to any existing session.

## Doer Agent (d4fdo)
A **d4fdo** subagent (`@d4fdo`) is available for executing tasks delegated by an architect/orchestrator agent:
- **Model**: DeepSeek V4 Flash (via OpenCode Zen) — fast and cost-effective
- **Full tool access**: can read, write, search, run bash, fetch web content, and load skills
- **No analysis/design** — it executes faithfully without questioning the approach
- **Concise reporting** — reports what was done, what changed, and any issues

### Usage Pattern
1. Architect agent analyzes a problem and produces a plan.
2. Architect delegates implementation to `@d4fdo` with clear, specific instructions.
3. d4fdo executes and reports back.
4. Architect reviews the result and may delegate follow-up work.

## For Subagents
- Use the **general** subagent (`@general`) for multi-step research and tasks that need tool access.
- Use **@explore** specifically for library/codebase investigation.
- Use **@d4fdo** for executing concrete tasks assigned by an orchestrator.
- Do not create throwaway subagent instances for questions that an existing session can answer.
