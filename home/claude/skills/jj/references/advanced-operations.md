# Advanced / less-common operations

Everything here was exercised at least once against a real repo. Grouped by whether
it's safe by default or needs the user's explicit go-ahead (same policy as
[safety-and-undo.md](safety-and-undo.md) — this file assumes you've read that one).

## Navigation: `jj next` / `jj prev`

Two modes, and the distinction matters for the rewrite policy:

- **Without `--edit` (default, safe):** creates a **new empty commit** as a sibling at
  the target position — never touches an existing commit.
  ```
  jj next          # D  @      D
                    # |    =>  |/
                    # C @      C
                    # |/       |
                    # B        B
  ```
- **With `--edit` (treat like `jj edit` — needs permission):** moves `@` directly onto
  an *existing* adjacent commit, which means further edits will rewrite it in place.

```bash
jj --no-pager next [offset]              # safe
jj --no-pager prev [offset]              # safe
jj --no-pager next --edit                # rewrite-adjacent — ask first
jj --no-pager prev --edit                # rewrite-adjacent — ask first
```

## `jj edit <rev>`

Moves `@` onto an existing commit for direct in-place editing. Respects immutability
(verified: attempting `jj edit` on a commit under `trunk()` gives the same
"is immutable" error as other rewrite commands — see
[safety-and-undo.md](safety-and-undo.md)). Rewrite-adjacent — needs explicit
permission, per this skill's default policy, even on mutable commits.

## `jj absorb`

Auto-distributes the *current* diff backward into whichever mutable ancestor commit
last touched each changed line, then rebases descendants. Verified: editing a line
that was introduced in the immediate parent, then running `jj absorb`, moved that
edit into the parent and left the (still-open, still-described) working commit empty
— no orphaned "fixup" commit, no manual squash needed. This is a rewrite of history
(it changes an ancestor's content) — ask first, unless the user is explicitly asking
you to "absorb these fixups."

```bash
jj --no-pager absorb                    # scans the whole current diff
jj --no-pager absorb <fileset>          # scoped to specific paths
```

## `jj duplicate`

Creates a **new** commit with the same content as an existing one, new change ID, not
linked to the original. Verified: `jj duplicate -r <rev>` reports
`Duplicated <hash> as <new-change> <new-hash> ...`. This is additive (the original is
untouched) but still rewrite-*adjacent* in spirit (it's jj's answer to
`git cherry-pick`, and duplicating history casually can be confusing) — ask first
unless it's clearly what was requested.

## `jj parallelize`

Turns a parent/child chain into siblings (declares two commits independent of each
other). Verified: `jj parallelize <rev1> <rev2>` on a two-commit chain made them both
direct children of the original shared ancestor, with no ordering between them
anymore. This changes graph structure — ask first.

## `jj metaedit`

Changes commit **metadata** (description, author, custom fields) without touching
content. Verified: `jj metaedit -r <rev> -m 'new message'` behaves like
`jj describe -r <rev>` but is the more general tool (also handles author/committer
via `--update-author` etc.). Same caution as `jj describe` — fine on an
already-finished parent commit, not on `@`.

## `jj revert`

Creates a **new** commit containing the inverse of a given commit's diff — like
`git revert`. Purely additive (verified: the original commit and its content are
completely untouched; the revert commit is placed whereever `--onto` /
`--insert-after` / `--insert-before` says, defaulting to none of those unless
specified — one of the three is **required**). Safe to use without asking, in the
same sense `jj new`/`jj commit` are, since nothing existing is modified — though as
always, only create it where it was actually requested.

```bash
jj --no-pager revert -r <rev> --onto @          # (--destination also works, hidden alias)
jj --no-pager revert -r <rev> --insert-after <rev2>
```

## `jj simplify-parents`

Removes redundant parent edges from merge commits (when one parent is already an
ancestor of another parent of the same commit, through some other path) without
changing any commit's actual content. Rewrites merge-commit metadata — ask first.

## `jj run`

**This is a rewrite operation, not a read-only "run tests" command** — easy to
mistake for the latter. Per its own `--help`: it checks out each targeted revision in
an isolated working copy, runs your command, and **amends the revision with the
resulting change**, then rebases descendants on top by default. Only use this when
the user specifically wants a formatter/linter/codemod applied across a range of
commits (its actual use case, e.g. `jj run -- pre-commit run`) — never as a way to
just "try running the tests," which would unexpectedly mutate history.

## `jj diffedit` / `jj arrange` — interactive only, skip

Both require an interactive diff editor / TTY-driven UI (confirmed via `--help`:
`diffedit` opens a diff editor on a revision's changes; `arrange` is described as
"Interactively arrange the commit graph" with no non-interactive mode). Not usable by
a non-interactive agent — don't attempt either; use `jj split`/`jj-hunk` (see
[splitting.md](splitting.md)) or `jj rebase` for the equivalent non-interactive
outcomes instead.

## File operations beyond `jj file annotate`

```bash
jj --no-pager file list [fileset]                 # list tracked files (see filesets.md)
jj --no-pager file show <path>                    # print file content at a revision
jj --no-pager file search --pattern <regex> [fileset]   # grep across tracked files
jj --no-pager file chmod x <path>                 # or `n` (normal) — sets/clears executable bit
jj --no-pager file track <path>                   # start tracking (rarely needed — see below)
jj --no-pager file untrack <path>                 # stop tracking
```

**Verified: `jj file untrack` refuses on a file that isn't gitignored**, with a
genuinely helpful error:
```
Error: '<path>' is not ignored.
Hint: Files that are not ignored will be added back by the next command.
Make sure they're ignored, then try again.
```
This matches [workspaces.md](workspaces.md)'s note that added files are tracked
automatically by default — `untrack` alone doesn't stick unless the path is also
excluded from future auto-tracking via `.gitignore`.

## Tags

```bash
jj --no-pager tag list
jj --no-pager tag set <name> -r <rev>
jj --no-pager tag delete <name>
```

Straightforward, verified working as documented. Tags are part of `immutable_heads()`
by default (see [revsets.md](revsets.md)) — tagging a commit makes its ancestors
immutable, same as trunk does.

## Sparse checkouts

```bash
jj --no-pager sparse list                          # currently-included patterns
jj --no-pager sparse set --add <path> --clear       # narrow to just <path> (verified)
jj --no-pager sparse reset                          # back to everything (verified)
jj --no-pager sparse edit                           # interactive — skip, same as diffedit/arrange
```

Sparse patterns control what's materialized on disk, not what's tracked in commits —
narrowing doesn't lose or hide any history, just local files. Low-relevance for most
agent tasks; mentioned for completeness.

## Operation log, beyond `undo`/`redo`/`op log`/`op restore`

```bash
jj --no-pager op show <op-id>                       # what that operation changed
jj --no-pager op diff --from <op-id> --to <op-id>   # diff between two operations
jj --no-pager op revert <op-id>                     # undo ONE past operation, keep everything after it
jj --no-pager op abandon <op-id>..<op-id>            # PERMANENTLY prune old operation history
jj --no-pager op integrate <op-id>                  # rare: re-link an orphaned operation (see --no-integrate-operation)
```

**`jj op revert` vs `jj op restore` vs `jj undo` — verified distinct semantics, worth
knowing precisely:**
- `jj undo` — undoes only the *most recent* operation.
- `jj op restore <id>` — jumps the *entire* repo state to exactly how it looked at
  that operation, discarding everything that happened after it (from the current
  view's perspective — still recoverable via `jj op log` since this is itself just a
  new operation).
- `jj op revert <id>` — surgically undoes **one specific past operation**, wherever it
  is in history, while **keeping** everything that happened after it. Verified:
  reverting a middle "set description" operation undid just that description change
  and left later commits/operations intact. This is the right tool when you want to
  undo one specific mistake buried in the past without losing subsequent work.

**`jj op abandon` is different from the others: it's a real, not-fully-reversible
prune**, not a "view the repo differently" operation. Per its own `--help`: it
discards operation history (and any commits/predecessors that become unreachable as a
result) so it can later be garbage collected. This is the one operation-log command
that reduces what `jj undo`/`jj op restore` can ever reach again — treat it as
needing explicit user permission, unlike `undo`/`redo`/`restore`/`revert`/`show`/
`diff`, which are all fully safe to use freely for investigation.
