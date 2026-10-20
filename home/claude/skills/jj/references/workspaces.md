# Workspaces (jj's term for Git worktrees)

A **workspace** is a working copy + its own `@` pointer, sharing the same underlying
repository (commits, operation log) as other workspaces. This is exactly what Git
calls a "worktree." Useful for running a long test in one workspace while continuing
to edit in another, or — for an agent — giving each parallel task its own directory
so edits never collide in a single working copy.

All commands below were run and verified against a real two-workspace setup in this
skill's lab (`/tmp/jjskill/lab` as the default workspace, `/tmp/jjskill/lab-ws1` as a
second workspace named `ws1`).

## Creating a workspace

```bash
jj --no-pager workspace add --name ws1 /path/to/new/workspace
```

- `--name` is optional; defaults to the destination directory's basename.
- By default the new workspace's `@` is created as a **sibling** of the current
  workspace's `@` — i.e. it shares the same parent(s), not the same commit. Use
  `-r/--revision <revset>` (repeatable, for a merge) to instead branch the new
  workspace's `@` off specific revision(s):
  ```bash
  jj --no-pager workspace add --name ws1 ../ws1 --revision main
  ```
- `--sparse-patterns copy|full|empty` controls what's checked out (default: copy the
  current workspace's sparse patterns).
- The destination directory must not exist, or must be empty.

## Listing / locating

```bash
jj --no-pager workspace list                    # all workspaces + their @ commit
jj --no-pager workspace root                     # path of the current workspace
jj --no-pager workspace root --name ws1          # path of a specific workspace
```

`jj log` marks each workspace's `@` with `<name>@` (the default workspace shows as
`default@`). Revsets can reference another workspace's working copy directly with
`<name>@`, e.g. `jj log -r 'ws1@'`, `jj diff -r 'ws1@'`.

## Working across workspaces from one place

All workspaces share the repo, so another workspace's `@` is readable from anywhere:

```bash
jj --no-pager log -r 'ws1@' --no-graph -T 'description'
jj --no-pager diff --git -r 'ws1@'
```

Read only. Never rewrite another workspace's `@` (`describe`, `squash`, `rebase`,
`-R <other path>`): that workspace is owned by whatever works in it, and its files go
**stale** (below). The one exception is User asking for that exact rewrite.

## Staleness and `jj workspace update-stale`

Every jj command does three things: (1) snapshot the working copy into a commit, (2)
compute the new repo state, (3) write the new `@`'s files back to disk. If step 3 is
interrupted, or another workspace changes *this* workspace's `@` out from under it,
the on-disk files no longer match what the repo thinks `@` should look like — that
workspace is "stale."

What another workspace's rewrite does to this one, measured on jj 0.46.0:

| Rewrite from elsewhere | Effect here |
| --- | --- |
| Move a bookmark this workspace follows (`main`) | Nothing visible. `@` stays put, now off `main`. |
| Change only a description of `@` or an ancestor | Not stale. Unsnapshotted edits survive. |
| Change the tree of `@` or an ancestor (rebase onto other content, squash into) | Stale. Every command here, `jj status` included, fails until `jj workspace update-stale`. |
| Same, with unsnapshotted edits on disk | `update-stale` puts the edits in a divergent orphan commit and moves `@` to a fresh empty one. The files look lost. |
| `jj -R <this path> ...` | Runs as this workspace: snapshots first, so edits survive. Still a rewrite of someone else's `@`. |

Recovery from a stale error:

```bash
jj --no-pager workspace update-stale
```

Divergent `@` afterwards: `jj log -r 'change_id(<id>)'` shows both commits; the
older one holds the edits that were on disk.

## Removing a workspace

```bash
jj --no-pager workspace forget          # forgets the CURRENT workspace
jj --no-pager workspace forget ws1      # forgets a named workspace, from elsewhere
```

**Verified: `forget` only unlinks the repo's record of the workspace — it does NOT
delete or touch anything on disk.** The directory, its `.jj/`, and all its files are
left exactly as they were. Confirmed empirically: after `jj workspace forget ws1`,
`ls` on the (former) `ws1` directory still shows every file untouched, but running
any `jj` command from inside it fails immediately with:
```
No working copy
```
That directory is now orphaned — it's not coming back by re-running `jj workspace
add` at the same path either (that would create an unrelated new workspace there,
and `jj workspace add` refuses a non-empty destination). If you want the directory
itself gone, delete it yourself (`rm -rf`), either before or after `forget` — order
doesn't matter, jj doesn't care about the directory's existence once it's forgotten.

This is an append-only-ish operation on the repo's view (undoable via `jj undo` like
anything else) but it does make that workspace's `@` no longer tracked, so treat
`forget`-ing a workspace that still has unfinished, undescribed work in it with the
same care as any other action that could strand uncommitted context — check `jj
status` in that workspace first if you're not sure it's done.

## Renaming

```bash
jj --no-pager workspace rename new-name
```

## Landing a workspace

The default workspace is tied to `main`. A secondary workspace is a branch off it.
Landing = the branch's commits enter `main`, and the default workspace ends on the
new `main`.

**Held = off limits.** `jj workspace list` gives each workspace's `@`. `main` is
always held by `default`. A bookmark on another workspace's `@` or `@-` is held by
that workspace. A secondary workspace never moves, sets, deletes or rewrites a held
bookmark, nor another workspace's `@`. It commits on its own `@` and on ancestors no
other workspace or bookmark holds, and moves only a bookmark it created for its task.

**Who lands.** Only the default workspace: its session, or User. A secondary
workspace that is ready stops (need_user, or a message to the default session) with
`ready to land: <change-id>`. No session in the default workspace means wait for
User, never land it yourself.

A repository's own `AGENTS.md`/`CLAUDE.md` finish steps (`jj bookmark set main ...;
jj git push`) are written for the default workspace. In a secondary workspace, stop
before the bookmark step.

Report position exactly: "on top of `main` (`main` not moved)", never "on `main`".
The short form reads as if `main` moved.

Thoughts that lead across the line. Each one is wrong:

- "A bookmark is only a label, moving `main` is harmless." The default workspace
  follows `main`; moving it leaves `default@` behind, and User's other sessions
  build on it.
- "Rebasing main's commits is fine, they are unpushed." A content change under
  another workspace's `@` makes it stale, and its unsaved edits end up in a
  divergent orphan (table under Staleness).
- "Nobody is in the default workspace, so I land it." Absence is not permission.
- "I'll bring `default@` along with `-R`." That rewrites someone else's working copy.
- "The repo's CLAUDE.md says `jj bookmark set main`." Written for the default
  workspace.

**How**, run from the default workspace. Any one of these, with `<tip>` the
secondary workspace's last finished commit (usually `<ws>@-`). Rewrite only mutable
(unpushed) commits, never `main@origin` or its ancestors.

```bash
# 1. Rebase onto main, fast-forward main.
jj rebase --branch <tip> --onto main
jj bookmark set main --revision <tip>

# 2. Merge commit. --no-edit keeps this workspace's @ where it is.
jj new --no-edit main <tip> --message 'merge: <task>'
jj bookmark set main --revision <that merge commit>

# 3. Rebase main's unpushed commits onto the workspace; main follows them.
jj rebase --source 'roots(main@origin..main)' --onto <tip>
```

Shapes 1 and 3 rewrite under the secondary workspace's `@`, so it goes stale. Safe
only because it stopped at `ready to land`; it runs `jj workspace update-stale`
before working again.

Then push `main` if the repository lands by pushing (its own `AGENTS.md` or
`CLAUDE.md` says).

**Advance the default workspace.** Moving `main` does not move `default@`. One
command covers every case: `@` empty, `@` with uncommitted changes, and local commits
in the default workspace that are not in `main` yet:

```bash
jj rebase --source 'roots(main..@)' --onto main
```

Run in the default workspace, so its files on disk update too. Already on
`main` → "Skipped rebase ... already in place", no change. A conflict lands in the
rebased commit: report it, do not resolve someone else's edit. Verified on jj 0.46.0.

Afterwards the secondary workspace's `@` still sits on the old branch. `jj new main`
there to keep working, or `jj workspace forget` it when the task is over.

## Practical pattern for agents: one workspace per parallel task

```bash
jj --no-pager workspace add --name task-a /tmp/proj-task-a --revision main
jj --no-pager workspace add --name task-b /tmp/proj-task-b --revision main
# work independently in each directory; each has its own @, no file collisions
# when done in one:
cd /tmp/proj-task-a && jj --no-pager commit -m 'feat: task a'
```

Each workspace's commits are immediately visible from every other workspace (it's one
repo) — `jj log` from anywhere shows every workspace's history, and you can `jj new`
a merge combining work from two workspaces without leaving either directory:

```bash
jj --no-pager new -m 'merge: combine task a and b' 'task-a@' 'task-b@'
```
