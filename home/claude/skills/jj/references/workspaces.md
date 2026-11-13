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

Read only. Never manipulate another workspace: no rewrite of its `@` or any mutable
ancestor of it (`describe`, `squash`, `rebase`, `abandon`, `absorb`), no `-R <other
path>`, `update-stale` or `forget` on it. That workspace belongs to whatever works in
it, and its files go **stale** (below). This holds from every workspace, `default`
included.

Exceptions: Agent is the sole agent owner of both workspaces (this session created or
took over both, and no other session works in either), or User asks for that exact
rewrite. Uncertain ownership is not ownership.

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

Landing = a workspace's finished commits enter `main`. Every workspace lands its
own work, `default` included, with one command:

```bash
pyjj commit -m '<message>'   # @ must be empty
pyjj wf land                 # --onto <bookmark> for a trunk other than main
```

One transaction (`croshome/home/pyjj/land.py`): rebase every root of `main..@`
onto `main` (`jj rebase -b @ -d main`), then move `main` to `@-`. The move is
forward, so pyjj's fast-forward guard passes it. Only the local bookmark moves.

Refusals, each writing nothing:

- `@` has changes: commit first.
- a commit in `main..@-` has no description.
- the rebase would rewrite a commit under another workspace's `@` (it would go
  stale). Land the shared base from the workspace that owns it, or ask User.
- the rebase introduces a conflict: resolve in this workspace's own commits, then
  land again.

Nothing to land: it moves `@` onto `main` and stops. That is how a workspace,
`default` included, catches up after another one landed. Run it in the workspace
itself, never with `-R` on someone else's.

**Held = off limits.** `jj workspace list` gives each workspace's `@`. A bookmark on
another workspace's `@` or `@-` is held by that workspace. No workspace moves, sets,
deletes or rewrites a bookmark another workspace holds, nor another workspace's `@`
or its mutable ancestors (exceptions above). `main` moves only through
`pyjj wf land`: never `bookmark set main` by hand, also when a repository's
`AGENTS.md`/`CLAUDE.md` finish steps say so.

Then push `main` if the repository lands by pushing (its own `AGENTS.md` or
`CLAUDE.md` says).

Report position exactly: "landed, `main` at <change-id>", or "on top of `main`
(`main` not moved)", never "on `main`".

When the task is over, `jj workspace forget` the workspace.

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
