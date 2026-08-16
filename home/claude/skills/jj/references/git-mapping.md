# Git ↔ jj concept and command mapping

Read this first if you know Git — it'll save you from the two mistakes that trip up
Git users the most: assuming there's a staging area, and assuming `jj commit` behaves
like `git commit`.

## Concept mapping

| Git concept | jj equivalent | The important difference |
|---|---|---|
| Working tree | Working copy | Same idea. |
| Index / staging area | **Doesn't exist.** | There is nothing to `add`. Whatever's in the working tree is already part of `@`, a real commit, as of the last jj command run (jj auto-snapshots on almost every invocation). "Unstaged" vs "staged" isn't a distinction jj has. |
| `HEAD` | `@` | `@` is *always* a real commit — there's no "detached HEAD" state, because jj has no concept of HEAD needing to be "attached" to a branch in the first place. |
| A branch (moves as you commit) | A bookmark | Bookmarks **do not move** when you commit or create new commits — only when explicitly moved, or when the commit they point at is rewritten (then jj follows automatically). "What branch am I on" isn't a jj question; there's no current-branch concept at all. |
| `git worktree add` | `jj workspace add` | Same idea — a second working directory backed by the same repo/history. jj calls it a *workspace*. |
| `git commit` (stages→commits, `HEAD` moves) | `jj commit -m 'msg'` | **Not the same shape.** See "`jj commit` vs `git commit`" below — jj's version also creates and moves to a brand-new *empty* commit afterward, git's does not. |
| `git commit --amend` | `jj describe` (message only) **or** `jj squash` (content) | Git's amend conflates message+content changes into one command; jj splits them. `jj describe` never touches content. |
| `git add -p` + multiple `git commit`s | `jj split <fileset>` (repeated), or `jj-hunk` for sub-file granularity | See "`jj split` vs `git add -p`" below — meaningfully different workflow, not just a syntax change. |
| `git reset --soft HEAD~1` | `jj squash --use-destination-message` (from the commit being un-done) | Folds `@` back into its parent, keeping the parent's message — closest jj equivalent to "undo my last commit but keep the changes staged." |
| `git reset --hard HEAD` | `jj abandon` (on `@`) or `jj restore` | Discards `@`'s changes. Since nothing is ever truly deleted in jj, this is safer than it sounds — recoverable via `jj undo`/`jj op log`. |
| `git checkout <rev>` (detach HEAD) | `jj new <rev>` | Just creates a new commit on top of `<rev>` and moves `@` there — no "detaching" concept needed, and **no special flag** is required even if `<rev>` is an old/ancestor commit (verified: `jj new --allow-backwards` does not exist in jj 0.43). |
| `git checkout <rev>` (then commit *onto* it, i.e. amend history in place) | `jj edit <rev>` | Exists, but treat as a rewrite requiring explicit user permission — see [safety-and-undo.md](safety-and-undo.md). |
| `git stash` | `jj new` (park current work by moving `@` elsewhere) or `jj squash` | There's nothing to "stash" really — your edits are already a real commit (`@`); just navigate away from it with `jj new <somewhere-else>` and come back later with `jj new <that-old-@'s-change-id>`. |
| `git reflog` | `jj op log` | jj's version covers *everything* (commits, bookmarks, workspaces), not just ref updates, and pairs with `jj undo`/`jj op restore`. |
| `git cherry-pick` | `jj duplicate` | Rewrite-adjacent — ask first. |
| `git rebase` | `jj rebase` | Broadly similar goal, meaningfully more flexible selection (`--source`/`--branch`/`--revisions`) — see [rebase-and-merge.md](rebase-and-merge.md). Ask first. |
| `git merge` | `jj new <rev1> <rev2>` | Creates the merge commit directly; no separate "merge commit" ceremony, no fast-forward special case to reason about. |
| `git log <revspec>` | `jj log -r '<revset>'` | Different, much more expressive query language — see [revsets.md](revsets.md). Do not skip this; a lot of jj's power over Git is here. |
| Commit SHA | Commit ID (changes on every rewrite) **and** Change ID (stable across rewrites) | jj has *two* identifiers per commit for a reason: change ID is what you should generally refer to a "logical commit" by, since it survives rebases/`describe`/`squash` etc.; commit ID is the content-addressed hash, like a Git SHA. |

## `jj commit` vs `git commit`

`git commit` takes whatever's staged, creates a commit, and moves `HEAD`/the current
branch to point at it. Nothing further happens automatically.

`jj commit -m 'msg'` does two things: it's exactly `jj describe -m 'msg'` (set the
message on the current `@`) followed by `jj new` (create a fresh **empty** child
commit and move `@` there). So after `jj commit`, `@` is *always* a brand-new empty
commit — you're never sitting "on" the commit you just finished the way `git commit`
leaves you sitting on the one it just made.

```
Before `jj commit -m 'msg'`:        After:

@  (has your edits, no message)     @' (NEW, empty — this is @ now)
|                              =>   |
P  (parent)                         @  (same content as before, now described 'msg')
                                     |
                                     P
```

This is why "finish a task" in jj means `jj commit`, not `jj describe` — `describe`
alone does step one only and leaves `@` open to absorb further, unrelated edits.

## `jj split` vs `git add -p` + multiple commits

In Git, splitting mixed changes into multiple commits means: stage part of the diff
(`git add -p`), commit it, repeat, until everything staged is committed — new commits
always land *after* whatever you already committed, and until you're done, the rest of
your changes just sit as uncommitted worktree/index state (not a commit at all).

`jj split <fileset> -m 'msg'` works differently because in jj your current edits are
*already* a commit (`@`) before you split anything. Splitting takes that existing
commit's diff and divides it in two, inserting the matched part as a **new commit
inserted before** the (still-open) remainder — not appending after it:

```
Before `jj split <fileset> -m 'msg'`:      After:

@  (edits: everything, no message)         @  (edits: only what did NOT match
|                                     =>    |   the fileset — SAME role as
P  (parent)                                 |   before, "still open", NEW
                                             |   change id)
                                             K  (edits: only what matched —
                                             |   "msg", SAME change id @ had
                                             |   before the split)
                                             P
```

Practically: you never have to decide the whole working copy is "done" before you can
commit part of it. You can keep splitting logical pieces off the front, repeatedly,
while `@` keeps absorbing new edits — and only the piece you just split (`K` above) is
finalized with a message; the rest stays exactly as malleable as it was before you
split. This is why this skill prefers `jj split` as the default way to turn mixed
work into clean commits, over accumulating everything in `@` and committing once. See
[splitting.md](splitting.md) for the full workflow, and [jj-hunk.md](jj-hunk.md) for
the same idea at sub-file (hunk) granularity.

## Read-only Git commands are fine in a colocated repo

jj repos backed by the Git backend (the default) are real Git repos on disk. If you're
more confident reading Git output, it's fine to use **read-only** git commands to
inspect state — `git log --oneline --graph --all`, `git diff`, `git show`, `git
status` — as long as you never run a Git command that *writes* (`commit`, `rebase`,
`merge`, `reset`, `cherry-pick`, `push`, `stash`, `tag`). Always do writes through jj.

## Quick command lookup

| Git | jj |
|---|---|
| `git status` | `jj status` (`jj st`) |
| `git log --oneline -25` | `jj log --limit 25 --template builtin_log_compact_full_description` |
| `git show <rev>` | `jj show -r <rev> --git` |
| `git diff` | `jj diff --git` (working copy vs its parent) |
| `git diff <a> <b>` | `jj diff --git --from <a> --to <b>` |
| `git add <path>` | nothing — already tracked/snapshotted; `jj file track <path>` only needed if `snapshot.auto-track` was narrowed |
| `git restore <path>` | `jj restore <path>` |
| `git branch` | `jj bookmark list` |
| `git branch -d <name>` | `jj bookmark forget <name>` (local only) or `jj bookmark delete <name>` (propagates) |
| `git checkout -b <name>` | `jj bookmark create <name>` (does not move `@`) |
| `git tag` | `jj tag list` / `jj tag set` / `jj tag delete` |
| `git push` | `jj git push --bookmark <name>` |
| `git fetch` | `jj git fetch` |
| `git clone` | `jj git clone` |
| `git worktree add <path>` | `jj workspace add <path>` |
| `git blame` | `jj file annotate <path>` |
