# Safety policy, undo, and the operation log

## The policy

**Never rewrite history unless the user explicitly asked for that specific rewrite.**
This applies regardless of whether jj itself would technically allow it — see the
immutability nuance below for why jj's own guardrail can't be relied on alone.

### Always fine (append-only, never modifies an existing commit's content/identity in a way that surprises anyone)

- `jj commit -m '...'` — commits `@`, opens a fresh empty child
- `jj new [-m '...'] [<rev>...]` — new empty commit; naming an old revision as parent
  just branches off it, no special flag needed (there is **no** `--allow-backwards`
  flag on `jj new` — verified against `jj new --help` on jj 0.43)
- `jj split <fileset> -m '...'` targeting `@` with no `-o`/`-A`/`-B` — only ever
  touches the one commit you named and appends a child
- `jj bookmark create <name> -r <rev>` — new pointer, nothing existing moves
- `jj describe -r @- -m '...'` — renaming an already-finished **parent** commit is
  fine; renaming `@` itself is the one thing to avoid (see next section)
- `jj squash --use-destination-message` — squashing `@` into its immediate parent for
  a trivial fixup is explicitly allowed without asking; it's equivalent to amending
  the commit you're actively working on, not touching finished/shared history
- `jj next` / `jj prev` **without** `--edit` — verified: these create a new empty
  sibling commit, never touch an existing one
- `jj revert` — creates a new commit with the inverse diff; the original is untouched
- `jj op log` / `op show` / `op diff` / `undo` / `redo` / `op restore` / `op revert` —
  all investigate-or-recover tools, safe to use freely (see below)

### Requires the user to have actually asked for it

- `jj edit <rev>` — moves `@` onto a past commit; any further edit rewrites that
  commit in place
- `jj next --edit` / `jj prev --edit` — same effect as `jj edit`, just phrased as
  relative navigation; same caution applies
- `jj rebase` (any form) — moves commits, changes ancestry
- `jj split` with `-o`/`-A`/`-B` targeting anything beyond `@`, or `-r <rev>` on a
  commit that isn't `@` — can rebase arbitrary descendants
- `jj absorb`, `jj duplicate`, `jj parallelize`, `jj metaedit`, `jj arrange`,
  `jj simplify-parents` — all rewrite existing commits or their relationships (full
  descriptions in [advanced-operations.md](advanced-operations.md))
- `jj run` — easy to mistake for a read-only "run the tests" command; it actually
  **amends** each targeted revision with the result and rebases descendants (verified
  from its own `--help`) — only use it when a formatter/codemod-across-history was
  specifically requested
- `jj bookmark move` / `jj bookmark delete` — retargets or removes a pointer someone
  else may be relying on
- `jj op abandon` — permanently prunes operation history; narrows what `undo`/
  `restore`/`revert` can ever reach again (unlike every other `op` subcommand, which
  is pure investigation/recovery)

### Absolute rule: never run a git command that writes, in any jj repo

**No exceptions, not even "just this once," not even when explicitly asked to use
git instead of jj for a write.** jj repos are backed by a real git repository, which
makes it *possible* to run `git commit`, `git merge`, `git rebase`, `git reset`,
`git cherry-pick`, `git push`, `git tag`, `git stash`, `git branch -d`, etc. directly
— but doing so bypasses jj's operation log entirely, so none of the recovery
machinery in this file (`jj undo`, `jj op restore`, checkpointing) can see or undo
it. A git write can silently desync jj's view of the repo from what's actually on
disk in `.git`, in ways that are confusing to diagnose and may not be cleanly
recoverable through jj at all. **Every write goes through `jj`, full stop** — use
[git-mapping.md](git-mapping.md) to find the jj equivalent of any git command you're
tempted to reach for.

Read-only git commands (`git log`, `git diff`, `git show`, `git status`,
`git blame`) are fine — they don't write anything, and jj repos are real git repos
under the hood, so they always reflect current state accurately for inspection.

### `jj describe` needs care, specifically

`jj describe` sets a message but does **not** create a new `@` the way `jj commit`
does. If you use it on `@` to "finish" a task, `@` stays open and the *next* edit —
even from an unrelated later step — silently lands inside the commit you just
described. Use `jj commit` to finish work; only use `jj describe -r @-` (explicitly
targeting the parent, not `@`) to touch up a message on a commit you already closed
out.

## Immutability: verified nuance for local/throwaway repos

jj has a built-in guard: commits under `immutable()` (by default, ancestors of
`trunk()`, tags, and untracked remote bookmarks — see
[revsets.md](revsets.md#built-in-aliases-overridable-in-config)) refuse rewrites
unless you pass `--ignore-immutable`. When it's armed, the error is explicit:

```
Error: Commit <id> is immutable
Hint: Could not modify commit: <change> <id> <description>
Hint: Immutable commits are used to protect shared history.
Hint: This operation would rewrite N immutable commits.
```

**Verified in this skill's lab, and important:** `trunk()` resolves against a
*remote's* main/master/trunk bookmark. **In a repo with no remote yet (or one where
nothing has been pushed), `trunk()` silently falls back to `root()`, so `immutable()`
is effectively just `{root}` — a local `main` bookmark does NOT make its history
immutable.** Concretely, in the lab: before `jj git push --bookmark main` to a real
remote, `jj describe` on an ancestor of the local `main` bookmark succeeded with zero
complaint. After pushing (so `trunk()` now correctly resolved to `main`'s pushed
position), the identical command failed with the "is immutable" error above.

**Practical consequence:** don't assume jj will stop you from rewriting "obviously
shared" history in a repo that happens not to have a remote configured (a very common
situation for scratch repos, freshly-scaffolded projects, or CI checkouts without a
push target). The policy at the top of this file is load-bearing on its own — it is
not just a backstop for jj's built-in check.

## `jj undo`, `jj redo`, and the operation log

Every jj command is one **operation**; operations form their own history (the
operation log), separate from and covering commit history, bookmarks, and workspace
`@` pointers together. This is what makes basically everything recoverable.

```bash
jj --no-pager op log --limit 10                 # what happened, most recent first
jj --no-pager undo                              # step back one operation (verified: works)
jj --no-pager redo                              # step forward again (verified: works, round-trips with undo)
jj --no-pager op restore <operation-id>         # jump the whole repo state to a specific past operation
jj --no-pager op revert <operation-id>          # undo just ONE past operation, keep everything after it
```

`jj undo` undoes the *last* operation, not a specific arbitrary one. For anything
older you have two different tools, and the distinction is worth being precise about
(both verified): `jj op restore <id>` jumps the **entire** repo back to that moment,
discarding everything since (recoverable — it's itself just a new operation);
`jj op revert <id>` surgically undoes **one specific** past operation wherever it is
in history while **keeping** everything that happened after it. Use `revert` when you
want to fix one buried mistake without losing later work; use `restore` when you
genuinely want to rewind everything. Both, plus `op log`/`op show`/`op diff`, are safe
to use freely — see [advanced-operations.md](advanced-operations.md) for the full
operation-log command set, including `jj op abandon`, which is the one operation-log
command that is **not** freely safe (it permanently prunes old operation history,
narrowing what `undo`/`restore`/`revert` can ever reach again — needs explicit
permission, unlike everything else in this section).

Because rewritten/abandoned commits become **hidden** rather than deleted (see
[revsets.md](revsets.md#hidden-vs-visible-commits)), you can generally also recover a
specific old commit directly by its commit ID even without touching the operation log,
as long as you still know (or can find, via `jj op log`) that ID.

### Do NOT chain multiple `jj undo` calls expecting "go back N steps" — verified footgun

This is a real, reproduced failure mode, not a theoretical one. `jj undo` undoes
whatever operation is *currently* last in the operation log — and **`jj undo` itself
generates operations** (jj snapshots the working copy before almost every command,
including `undo`). So a second `jj undo` does not necessarily undo "the operation
before the one the first undo removed" — it may instead undo a *snapshot operation
that the first undo itself just created*, which is not what a human (or agent)
chaining "undo, undo" intends.

**Reproduced concretely:** three commits (`step 1`, `step 2`, `step 3`) were created
in sequence. Calling `jj undo` twice in a row was intended to get back to right after
`step 1`. Instead: the first `undo` correctly undid `step 3`'s `jj commit`. The
second `undo` did *not* undo `step 2`'s commit — it undid the **snapshot operation
that the first undo had just performed**, which landed on a state from *before*
`step 3`'s content was ever captured. Net effect: `step 3`'s working-copy file
(`c.txt`) **disappeared from disk** (`Added 0 files, modified 0 files, removed 1
files` in the command output) — not because it was "two steps back" from a sane
mental model, but because of this snapshot-interleaving quirk.

**The good news, also verified:** nothing was actually lost. The exact operation ID
from the very first `commit -m 'step 3'` was still visible in `jj op log`, and
`jj op restore <that-id>` brought `c.txt` and the full three-commit history back
immediately, byte for byte. jj's "nothing is destroyed" guarantee held — but a naive
agent that saw "removed 1 files" and didn't know to look at `jj op log` could easily
have panicked, or worse, tried to "fix" it by recreating the file from memory instead
of just restoring the operation, silently diverging from what was actually there.

**Rule of thumb:** never call `jj undo` more than once in a row on faith. After any
`jj undo`, look at `jj op log` (or `jj status`/`jj log`) before deciding whether to
undo again — confirm what you're about to undo next, don't assume. If you need to
back out more than one operation, prefer `jj op restore <id>` to a *specific,
already-identified* operation ID over repeated `undo` calls.

### Checkpointing: record an operation ID before risky or multi-step work

Because of the above, the reliable way to get a safe rollback point — especially
before a sequence of several jj operations, or before letting yourself work more
freely/autonomously — is to **record the current operation ID up front**, not to
plan on chaining `undo` afterward:

```bash
jj --no-pager op log --no-graph --limit 1 -T 'id.short() ++ "\n"'
# e.g. a4f03cd46b96 — note this down before starting a risky sequence
```

If anything goes wrong later in the sequence — however many jj operations deep —
`jj op restore <that-id>` returns to *exactly* that starting point in a single,
precise step, verified equivalent to "as if none of the intervening work had
happened" (commits, bookmarks, and working-copy state all included, since an
operation is a full repo snapshot, not just a commit-graph snapshot). This is
strictly more reliable than counting `jj undo` calls.

**This is also what makes it reasonable for a capable agent to work more
autonomously through a multi-step jj sequence**: record the checkpoint operation ID
first, proceed, and verify at the end (see below) — if the end state isn't what was
intended, there's a known-good, exact, single-command way back, so the downside of
an autonomous multi-step sequence going sideways is bounded and cheap to recover
from. This does not relax the rewrite-permission policy above — it's about
confidence in *recovering from mistakes*, not about license to rewrite history
without being asked.

## Verify your work, and know when to stop instead of self-correcting

After a jj operation (or a small logical group of them), **check that the result
actually matches what you intended** — don't assume a command that exited 0 did what
you meant. `jj status` and `jj log -r '<relevant revset>'` (see
[revsets.md](revsets.md)) are cheap; use them.

If verification shows something is wrong, the response depends on how deep the
problem is:

- **A single, obviously-wrong last step** (e.g. you just ran the wrong revset, split
  the wrong file into the wrong commit, described the wrong revision) — it's fine to
  self-correct immediately with **one** `jj undo` (or one `jj op restore` to a
  checkpoint you already recorded), then retry correctly. This is normal course
  correction, not a "fix a mess" operation.
- **Anything deeper** — multiple operations already happened since the mistake,
  you're not sure exactly which operation introduced the problem, the repo is in a
  conflicted/divergent state you didn't expect, or you're simply not confident what
  went wrong — **stop. Do not attempt further jj operations to try to fix it.**
  Explain to the user, concretely: what you were trying to do, what you observe now
  (paste the relevant `jj status`/`jj log`/`jj op log` output), a specific suggested
  next step (e.g. "I believe `jj op restore <id>` would return to the state before
  this started"), and then wait for the user's go-ahead before touching the repo
  again. Guessing your way out of an unclear state risks compounding the problem —
  exactly the scenario `jj undo` alone won't cleanly fix (per the chaining pitfall
  above), and where a wrong guess is harder to reason about than the original
  mistake.

This is why checkpointing (previous section) is worth doing proactively: it turns "I
don't know how to get back" into "I know the exact command," which is precisely the
distinction between a problem to escalate and a problem to just fix.

## Working-copy staleness

Not really a safety issue but adjacent — see
[workspaces.md](workspaces.md#staleness-and-jj-workspace-update-stale) for the
verified behavior of `jj workspace update-stale`.

## Global flags relevant to safety

| Flag | Effect | Use for AI agents? |
|---|---|---|
| `--ignore-immutable` | bypasses the immutability check | No, unless explicitly asked for the specific rewrite it's guarding |
| `--ignore-working-copy` | skips snapshotting the working copy first | No — always work against real on-disk state |
| `--at-operation <op>` | run a read query as of a past operation | Fine for read-only historical inspection |
