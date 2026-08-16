# Git remotes: clone, fetch, push, and divergence

Everything here was verified with a real two-clone setup: a bare git repo as a shared
`origin`, and two **independent** `jj git clone`s of it (not workspaces — separate
`.jj` directories, separate operation logs, exactly like two different people/machines
would have). Divergence and conflict scenarios were reproduced and resolved for real,
not inferred from docs.

## Cloning

```bash
jj --no-pager git clone <url-or-path> <dest>
```

Verified against a real GitHub remote (`jj-vcs/jj.git`): clone auto-tracks **the
remote's default branch** (whatever its `HEAD` symref points to — this is exactly the
mechanism GitHub/GitLab/etc. use to advertise "the default branch," so real-world
clones just work: `jj new main` works immediately after cloning). Output confirms
this explicitly: `Setting the revset alias 'trunk()' to 'main@origin'`, and
`jj bookmark list` shows a plain, already-tracked `main` (not `main@origin`).

**No other bookmark is auto-tracked.** A clone of a repo with `main` and `feature`
bookmarks leaves `feature@origin` untracked — `jj new feature` will fail with
`Revision 'feature' doesn't exist / Hint: Did you mean 'feature@origin'?` until you
run `jj bookmark track feature --remote=origin`.

**Troubleshooting a clone where even the default branch didn't track:** this can only
happen if the *remote itself* is misconfigured — specifically if its `HEAD` symref
points at a branch that doesn't exist (verified by reproducing it: a hand-made bare
repo whose `HEAD` still pointed at `refs/heads/master` after only ever having a
`main` branch pushed to it left *everything* untracked on clone). If `jj new main`
fails right after cloning a repo you'd expect to have a normal default branch, check
the remote's own `HEAD`:
```bash
git -C <bare-repo-path> symbolic-ref HEAD     # or, for a remote server, ask its admin
```
This is a remote-misconfiguration issue, not a jj quirk — don't treat it as something
to routinely work around.

## Fetching

```bash
jj --no-pager git fetch                        # default remote
jj --no-pager git fetch --remote <name>
```

Updates every remote-tracking bookmark (`<name>@<remote>`), and — for *tracked*
bookmarks only — moves the corresponding local bookmark to match (merging if both
sides moved compatibly, conflicting if they moved incompatibly — see Divergence
below). Untracked remote bookmarks just get their `@<remote>` position updated; the
local bookmark (if any) is untouched.

## Pushing

```bash
jj --no-pager git push --bookmark <name>        # push one bookmark (verified flag name; NOT --allow-new)
jj --no-pager git push --all
```

Verified: `jj git push` labels what kind of move it's making, right in its output —
worth reading, it tells you exactly what's about to happen:
- `[add to <hash>]` — brand new bookmark on the remote
- `[move forward from <a> to <b>]` — fast-forward (descendant of the old position)
- `[move sideways from <a> to <b>]` — a **rewrite** of the same lineage (e.g. after
  `jj describe`/`jj rebase` on an already-pushed commit) — still allowed, as long as
  the remote's actual state still matches what you last fetched
- rejection — see next section

## Rejection: the safety check in action

If the remote has moved since your last fetch (someone else pushed), your push is
refused, verified literal output:
```
Warning: The following references unexpectedly moved on the remote:
  refs/heads/<bookmark> (reason: stale info)
Hint: Try fetching from the remote, then make the bookmark point to where you want
it to be, and push again.
Error: Failed to push some bookmarks
```
This is jj's built-in equivalent of `git push --force-with-lease`, always on, no flag
needed. The fix is exactly what the hint says: `jj git fetch`, reconcile (see below
if it's now conflicted), then push again.

## Divergence: two people rewrite the same commit independently

This is the scenario worth understanding deeply — it's genuinely two *different*
things happening at once, and the terminology matters:

- A **bookmark conflict** is about the *name* — `feature` can't decide which of two
  commits it should point to.
- A **divergent change** is about the *change ID* — the same logical change now has
  more than one visible commit.

They show up together whenever two clones independently rewrite a commit that a
bookmark points to, then both try to publish it. Verified end-to-end:

1. Both clones start with an identical commit (via push+fetch+track) under a bookmark
   `feature`.
2. Clone A rewrites it (`jj describe -r feature -m '...(A)'`) and pushes — succeeds
   ("move sideways").
3. Clone B, **without fetching first**, independently rewrites the same original
   commit differently and tries to push — **rejected** (see previous section).
4. Clone B runs `jj git fetch`. Now:
   - `jj status` warns: `These bookmarks have conflicts: feature` with a hint to use
     `jj bookmark list` / `jj bookmark set <name> -r <rev>`.
   - `jj log` shows **both** versions of the commit, each labeled `(divergent)`, using
     **change-offset notation** to disambiguate them since they share one change ID:
     `abcd1234/0` and `abcd1234/1` (this is the same mechanism described in
     [revsets.md](revsets.md) under change IDs — not just a doc curiosity, it's what
     you'll actually see). The bookmark name itself is shown suffixed `??` on each
     candidate: `feature??`.
   - `jj bookmark list` shows the conflict in diff form:
     ```
     feature (conflicted):
       - <old-common-ancestor> (hidden) ...
       + <change>/1 <hash> (divergent) ...(B)
       + <change>/0 <hash> (divergent) ...(A)
       @git (behind by 1 commits): ...
       @origin (behind by 1 commits): ...
     ```
     **`@git` shows up here as if it were a remote, even though this is not a
     colocated repo.** jj's git backend always maintains its own internal git ref
     namespace and reports it as a synthetic `@git` pseudo-remote in bookmark
     listings — don't mistake this for evidence of colocation.
   - `jj log -r 'divergent()'` finds exactly the two conflicting commits.
   - **Referencing the bare change ID now hard-errors** (verified literal text —
     good to quote back to a user or use directly as next-step guidance):
     ```
     Error: Change ID `abcd1234` is divergent
     Hint: Use change offset to select single revision: abcd1234/0, abcd1234/1
     Hint: Use `change_id(abcd1234)` to select all revisions
     Hint: To abandon unneeded revisions, run `jj abandon <commit_id>`
     ```

### Resolving it

```bash
# Option A: pick one side outright
jj --no-pager bookmark set feature -r 'abcd1234/0'

# Option B: reconcile both into a merge, then point the bookmark at that
jj --no-pager new 'abcd1234/0' 'abcd1234/1' -m 'merge: reconcile divergent feature'
jj --no-pager bookmark set feature -r @
jj --no-pager git push --bookmark feature
```

Verified: after either resolution and a push, the *other* clone fetches cleanly with
no conflict — `feature` resolves unambiguously again.

**Non-obvious and worth remembering: resolving the bookmark conflict does NOT clear
the divergent-change marker on the two original commits.** Verified: after merging
both sides, `jj log -r 'divergent()'` still lists the two original commits as
`(divergent)` — they're now ordinary ancestors of the merge commit, still visible,
so the change ID genuinely still has more than one visible commit. This is expected
and harmless, not a sign the merge failed. If you want it fully gone (not just
resolved-via-merge), `jj abandon <commit-id>` the side you don't want to keep as
history — this is a real rewrite (of your own local view of that change) and only
worth doing if a clean single-lineage history actually matters more than keeping the
reconciliation record.

## Practical guidance for an agent hitting a divergent change

1. Don't panic — a divergent change and a bookmark conflict are both fully
   recoverable, same as anything else in jj (nothing was destroyed).
2. Read what `jj status`/`jj log` are telling you: which name is conflicted (`??`),
   which change ID is divergent (shows as `id/0`, `id/1`, ...).
3. Look at both sides: `jj log -r 'change_id(<prefix>)'` (matches all of them) or
   address them individually via the offsets jj's own error suggests.
4. Decide: is one side simply wrong (pick it: `jj bookmark set`), or do both sides
   have content worth keeping (reconcile: `jj new <side0> <side1> -m '...'` then
   `jj bookmark set`)? This is a judgment call about the *content*, not something to
   automate blindly — if it's not obvious which side should win, this is a good
   moment to surface the conflict to the user rather than guess.
5. Push the resolution. Don't be surprised that the old commits keep showing
   `(divergent)` afterward.
