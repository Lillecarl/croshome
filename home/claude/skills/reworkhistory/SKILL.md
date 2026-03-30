---
name: reworkhistory
description: Restructure jj commits to be true to their concern using programmatic hunk selection. Use when commits contain mixed concerns, when the user asks to "rework" or "split" commits, or when history needs to be broken into cleaner logical units.
---

Restructure commits to ensure each one represents a single, coherent concern. Uses `jj-hunk` for programmatic hunk selection.

## When to Use This Skill

- A commit contains unrelated changes (e.g., refactoring mixed with feature work)
- Multiple commits should logically be one (scatter-gather pattern)
- The user asks to "split" or "rework" commits
- Preparing commits for a cleaner PR/RFC
- Breaking a WIP commit into publishable units

## Invocation

When the user invokes this skill, they may specify a revset. Common patterns:

- `reworkhistory` — rework all mutable commits (default)
- `reworkhistory rk..@` — rework commits on the current branch back to `rk`
- `reworkhistory @-- 3` — rework the last 3 commits

The skill receives the revset as the first argument.

## Core Workflow (Serial)

**Process each commit serially, oldest first.** After each operation, verify state before proceeding to the next.

1. Run `jj log -r '$revset' --no-pager --template builtin_log_detailed` to list all target commits with their full messages and revids.

2. For each commit (oldest first), spawn a **dedicated subagent pair** with full context for that commit:
   - **Decision agent**: Inspect this specific commit, decide split/squash/keep
   - **Execution agent**: Run jj-hunk commands for this specific commit only

3. After each commit:
   - Run `jj log -r '$revset' --no-pager --template builtin_log_detailed` to confirm state
   - Proceed to next commit only after verifying success

### Decision Agent (per commit)

Pass to the subagent:
- Full `jj log` output (for adjacent commit context)
- This commit's revid and current message
- The revsets of adjacent commits

The agent must run:
- `jj diff --git --revisions $rev` to see what changed
- `jj show --summary -r $rev` for file-level view
- `jj log -r $rev-1..$rev --no-pager` for parent diff context

Return a structured decision:
- **keep**: commit is clean, no changes needed
- **squash**: belongs with parent, reason why
- **split**: which files/hunks go with which concern, suggested jj-hunk commands

### Execution Agent (per commit)

Pass to the subagent:
- The decision from the decision agent
- The full jj log context

The agent runs the jj-hunk commands for this commit and confirms execution.

## Decision Framework

### Split When

- Unrelated files changed in one commit
- A single file has distinct logical changes (e.g., "rename function" + "add feature using it")
- Mixed refactoring and behavior change
- Infrastructure setup (imports, deps) separate from usage

### Squash When

- Commit continues the same concern as its parent
- Small fixes/tweaks that belong with the main change
- Documentation that supports the previous commit

## jj-hunk Commands

### Split a Commit

Keep only specific files, reset the rest to working copy:

```bash
jj-hunk split '{
  "files": {
    "src/db/schema.ts": {"action": "keep"}
  },
  "default": "reset"
}' "feat: add database schema"
```

### Extract Specific Hunks

```bash
jj-hunk split '{
  "files": {
    "src/lib/utils.ts": {"hunks": [0, 2]}
  },
  "default": "reset"
}' "refactor: clean up utils"
```

### Squash into Parent

```bash
jj-hunk squash '{
  "files": {
    ".": {"action": "keep"}
  }
}'
```

## Agent Guidelines

- Use `jj log -r '<revset>' --no-pager --template builtin_log_detailed` to list target commits
- Process oldest commits first — later commits may depend on earlier ones
- Never use pipes to filter command output
- After splitting, use `jj describe` to refine commit messages
- Report what was split/squashed and why each decision was made
