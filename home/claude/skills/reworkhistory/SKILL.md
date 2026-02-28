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

## Core Workflow

### Phase 1: Analyze (Parallel)

1. Run `jj log -r '<revset>' --no-pager` to get all target commits with their full messages and revids.

2. Spawn **one subagent per commit**, all in parallel. Pass to each subagent:
   - The full `jj log` output (for adjacent commit context)
   - The commit's revid and current message
   - **Never use pipes** to filter command output

   Each subagent must:
   - Run `jj show --summary -r $rev` to see file-level changes
   - Run `jj-hunk list --rev $rev` to see the commit's hunk structure
   - Review adjacent commits for additional context
   - Determine: split, squash, or leave as-is
   - If split: identify which hunks belong to which concern
   - If squash: confirm it belongs with the parent
   - Return a structured recommendation with reasoning

3. Collect all recommendations back in the main agent.

### Phase 2: Execute (Serial)

4. Main agent reviews all recommendations and decides the final execution order (oldest first).

5. **Execute serially, oldest to newest.** After each operation:
   - Re-run `jj log -r '<revset>' --no-pager` to confirm state
   - Proceed to the next commit only after verifying the previous operation succeeded

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

## Examples

### Split Mixed Changes

A commit touches schema, routes, and utils:

```bash
# 1. Inspect
jj-hunk list

# 2. Extract infrastructure first
jj-hunk split '{
  "files": {
    "src/db/schema.ts": {"action": "keep"}
  },
  "default": "reset"
}' "feat: add database schema"

# 3. Remaining changes become subsequent commits
jj-hunk split '{
  "files": {
    "src/api/routes.ts": {"action": "keep"}
  },
  "default": "reset"
}' "feat: add users endpoint"

# 4. Final piece
jj describe -m "refactor: clean up utils"
```

### Extract Specific Hunks

A file has refactoring (hunks 0, 2) and new feature (hunk 1):

```bash
jj-hunk split '{
  "files": {
    "src/lib/utils.ts": {"hunks": [0, 2]}
  },
  "default": "reset"
}' "refactor: clean up utils"

# Hunk 1 remains in working copy
jj describe -m "feat: add helper function"
```

### Keep Everything Except One File

```bash
jj-hunk split '{
  "files": {
    "src/wip.rs": {"action": "reset"}
  },
  "default": "keep"
}' "feat: complete implementation"
```

### Squash into Parent

A small fix commit that belongs with its parent:

```bash
jj-hunk list --rev @

# Squash everything into parent
jj-hunk squash '{
  "files": {
    ".": {"action": "keep"}
  }
}'

# Then fix the parent message
jj describe -m "feat: implement feature with correct behavior"
```

## Agent Guidelines

- Use `jj log -r '<revset>' --no-pager` to list target commits (default to `mutable()` if no revset given)
- Never use pipes to filter command output — work with full output directly
- Consider adjacent commits when deciding splits — related changes may belong together
- Prefer explicit hunk indices or stable ids when building specs
- Use `"default": "reset"` for safer explicit inclusion
- After splitting, use `jj describe` to refine commit messages
- Report what was split/squashed and why each decision was made
