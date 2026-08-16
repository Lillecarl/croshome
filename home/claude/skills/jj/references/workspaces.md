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

Because all workspaces share the repo, you can inspect or even rewrite another
workspace's `@` from wherever you're standing, without `cd`-ing there:

```bash
jj --no-pager log -r 'ws1@' --no-graph -T 'description'
jj --no-pager diff --git -r 'ws1@'
```

This is convenient, but if you rewrite another workspace's `@` from outside it (e.g.
`jj describe -r 'ws1@' -m '...'` from the default workspace, or squashing it into its
parent), that workspace's on-disk files can go **stale** relative to the repo state —
see below. (As with any rewrite, only do this if you were asked to touch that other
task's work — otherwise treat each workspace as owned by whatever is working in it.)

## Staleness and `jj workspace update-stale`

Every jj command does three things: (1) snapshot the working copy into a commit, (2)
compute the new repo state, (3) write the new `@`'s files back to disk. If step 3 is
interrupted, or another workspace changes *this* workspace's `@` out from under it,
the on-disk files no longer match what the repo thinks `@` should look like — that
workspace is "stale."

**Verified in the lab:** in ordinary use you rarely need to think about this. Running
*any* jj command inside the stale workspace (even just `jj status`) re-syncs it
automatically as part of its normal step-3 file update — no explicit action needed. In
one lab test, squashing `ws1@` into its parent from the *default* workspace, then
immediately running `jj status` inside `ws1`, silently picked up the new state with no
staleness warning at all.

`jj workspace update-stale` exists for the harder case: jj detected staleness and
*refused* to proceed automatically (this happens in narrower situations, e.g. after
the recorded operation itself was lost, such as via `jj op abandon`). If you ever see
an explicit "stale working copy" error from a command, run:

```bash
jj --no-pager workspace update-stale
```

If the lost-operation case applies, this creates a recovery commit containing
whatever was on disk, parented onto the current operation's real `@` — so nothing
gets silently discarded.

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
