---
name: jj
description: Jujutsu (jj) version control. Use for all VCS work in a jj (or colocated jj/git) repository — committing, splitting, branching, rebasing, merging, workspaces, and revset queries. Prefers jj split over other splitting tools and never rewrites history unless explicitly asked.
---

# jj (Jujutsu) VCS

Jujutsu has no staging area, no detached HEAD, and (mostly) reversible operations.
The working copy `@` **is** a commit; edits are auto-snapshotted into it. This file
is the entry point — it gives you the golden path and a decision guide, then points
to `references/*.md` for depth. Read a reference file when a task actually touches
that topic; don't preload all of them.

All facts in this skill were verified by hand against jj 0.43.0.

## Core mental model (coming from Git)

Full command-by-command and concept-by-concept table:
[references/git-mapping.md](references/git-mapping.md). Read it early if you know
Git — the two habits that cause the most friction are assuming there's a staging
area, and assuming `jj commit` behaves like `git commit`. Neither is true:

- `@` = the working-copy commit, in **every** workspace (workspace = Git's
  "worktree"; `jj workspace add` = `git worktree add`). It's a real commit, always —
  not an index/staging area. There is no `git add`; edits are auto-snapshotted into
  `@` by almost every `jj` command. `@` also means there's no "detached HEAD" —
  `@` can sit on any commit, old or new, with no special mode to reason about.
- Two identifiers per commit: **change ID** (stable across rewrites — the thing to
  treat as "this logical commit's identity") and **commit ID** (content hash, changes
  on every rewrite — like a Git SHA). `jj log` shows change IDs at the start of a
  line, commit IDs at the end.
- Bookmarks = Git branches, but **do not move automatically** when you commit — only
  when explicitly moved, or when the commit they point to is rewritten (jj follows
  automatically). There is no "current branch" concept in jj at all.
- **`jj commit -m 'msg'` is literally `jj describe -m 'msg'` followed by `jj new`**
  (this is jj's own documented equivalence): it labels the *current* `@` and then
  creates a fresh **empty** child, moving `@` there. You never end up "sitting on"
  the commit you just finished, unlike `git commit`.
- **`jj split <fileset> -m 'msg'` inserts a new commit *before* the still-open working
  commit**, rather than appending after it the way repeated `git add -p && git
  commit` would: it peels the matched files out of `@`'s current diff into a new
  commit, and what's left keeps being `@` (still open, still absorbing edits, just a
  new change ID — see [splitting.md](references/splitting.md) for the exact diagram
  and the verified bookmark-following behavior, which is *not* symmetric with the
  change-ID story). This is why you don't have to decide the whole working copy is
  "done" before landing any of it — you can keep peeling logical commits off the
  front indefinitely.
- **Nothing is destroyed by rewriting.** Abandoned/rewritten commits become "hidden,"
  not deleted, and `jj undo` / `jj op log` can bring back any prior repo state. This
  makes rewrites *recoverable*, not *safe to do casually* — see Safety below.

## Golden path for finishing work

1. Make edits. jj auto-snapshots them into `@`.
2. Decide how to land them — in order of preference:
   - **One logical change** → `jj commit -m 'message'` (commits `@`, opens a new
     empty `@` child). This is the default 95% case.
   - **Mixed changes that should become several commits** → **`jj split <fileset> -m
     'message'`**, repeated (the preferred workflow — see
     [references/splitting.md](references/splitting.md)). This is non-interactive
     and safe when you pass file paths; no editor, no extra tool required.
   - **Mixed changes within a *single* file** (finer than file granularity) → same
     doc, section on `jj-hunk` (a companion CLI for hunk-level, non-interactive
     splitting) plus [references/jj-hunk.md](references/jj-hunk.md) for full detail.
   - **A trivial fixup that belongs in the previous commit** → `jj squash
     --use-destination-message` (allowed without asking — see Safety).
3. End in a clean state: `@` empty, all finished work committed with a real message.

**Never use `jj describe` to "finish" work.** It sets a message but does *not* create
a new `@` — further edits silently land back in the commit you just described. Use
`jj describe -r @-` only to rename an already-finished parent commit.

## Passing commit messages safely

Inline `-m '...'` breaks the moment the message contains an apostrophe: the shell ends
the single-quoting there and executes the rest of the message as commands. Real
incident: a body saying "that repo's dev conveniences" mangled a description and ran
half the message through bash.

So: reserve `-m 'one liner'` for messages you have checked contain no `'`, `"`, `` ` ``
or `$`. For every real message — anything with a body — pass it through a **quoted
heredoc** via command substitution, which survives all of those verbatim (verified on
jj 0.44.0):

```bash
jj commit -m "$(cat <<'EOF'
subject line

Body paragraph. Apostrophes, "double quotes", $vars and `backticks` are safe.
EOF
)"
```

The same substitution works for every command that takes `-m`, including `jj split`
and `jj describe`. To set or rewrite a whole description without opening an editor,
`describe --stdin` reads it straight from stdin:

```bash
jj describe -r @- --stdin <<'EOF'
the corrected message
EOF
```

## Decision guide: which command?

| Situation | Command |
|---|---|
| All edits in `@` are one logical change | `jj commit -m '...'` |
| Edits span multiple files, want them as separate commits | `jj split <fileset> -m '...'` (repeat) — [splitting.md](references/splitting.md) |
| One file mixes two concerns | `jj-hunk` hunk-level split — [jj-hunk.md](references/jj-hunk.md) |
| Small fixup belongs in parent | `jj squash --use-destination-message` |
| Need a merge of two lines of work | `jj new -m 'msg' <rev1> <rev2>` — [rebase-and-merge.md](references/rebase-and-merge.md) |
| Need to move commits onto a new base | `jj rebase --source/--branch/--revisions --onto <dest>` — **ask first**, see Safety |
| Need to pick specific commits/query history | revset — [revsets.md](references/revsets.md) |
| Need parallel working directories (e.g. one per task) | `jj workspace add` — [workspaces.md](references/workspaces.md) |
| Naming a line of development, or pushing | bookmarks — [bookmarks.md](references/bookmarks.md) |
| Cloning, fetching, pushing, or anything involving a second clone/remote | [remotes-and-sync.md](references/remotes-and-sync.md) — includes a full verified divergent-change walkthrough |
| Something went wrong | `jj undo` / `jj op log` — [safety-and-undo.md](references/safety-and-undo.md) |
| A less-common command not covered above (`jj edit`, `absorb`, `duplicate`, `parallelize`, `metaedit`, `run`, tags, sparse, `op` subcommands, ...) | [advanced-operations.md](references/advanced-operations.md) |
| Coming from Git, want a quick command lookup | [git-mapping.md](references/git-mapping.md) |

## Query history precisely: revsets

Don't guess at `HEAD~3`-style offsets or scroll through `jj log` output by eye — jj's
**revset** language (`-r/--revisions '<expr>'`, accepted by almost every command) lets
you select exactly the commits you mean, by graph relationship, author, date,
description, file touched, conflict state, and more. This is one of jj's biggest
advantages over Git and is worth using deliberately, not just for `jj log`:

```bash
jj --no-pager log -r 'trunk()..@'                        # local work not yet on trunk
jj --no-pager log -r 'mine() & description(glob:"fix:*")'  # your commits whose message starts with "fix:"
jj --no-pager log -r 'reachable(@, mutable())'            # the whole stack you're currently building
jj --no-pager log -r 'conflicts()'                        # anything with unresolved conflicts
jj --no-pager diff -r 'A::B'                              # diff over the ancestry path from A to B
```

Full grammar (operators with precedence, every function, string/date pattern syntax,
worked examples, and the `trunk()`-resolves-to-`root()`-with-no-remote gotcha): see
[references/revsets.md](references/revsets.md).

## Safety: don't rewrite history unless asked

jj *can* rewrite commits (`jj edit`, `jj rebase`, `jj absorb`, `jj duplicate`,
`jj parallelize`, `jj metaedit`, bookmark moves onto a different target) and it's
recoverable via `jj undo`. That does not mean an agent should reach for these by
default. **Only use rewrite commands when the user explicitly asks for that specific
rewrite.** Appending (`jj commit`, `jj new`, `jj split` on `@`, `jj bookmark create`)
is always fine.

**Important nuance verified in this skill's lab:** jj's own `immutable()` protection
(which blocks rewrites of commits under `trunk()`) only activates once the repo has a
real remote with a pushed trunk-like bookmark (`main`/`master`/`trunk` on
`origin`/`upstream`). In a local-only or freshly-initialized repo, `trunk()` silently
resolves to `root()` and **nothing is protected** — jj will happily let you rewrite
commits a human would consider "already shared." Don't rely on jj to stop you; follow
this skill's policy regardless of whether jj's guardrail happens to be armed. Full
detail and the exact error jj gives when it *is* armed: see
[safety-and-undo.md](references/safety-and-undo.md).

**Absolute rule, no exceptions: never run a git command that writes, in any jj
repo** (`git commit`, `git merge`, `git rebase`, `git reset`, `git cherry-pick`,
`git push`, `git tag`, `git stash`, `git branch -d`, ...). It's technically possible
since jj repos are real git repos, but it bypasses jj's operation log entirely, so
none of jj's recovery tools can see or undo it. Every write goes through `jj` — find
the equivalent in [git-mapping.md](references/git-mapping.md). Read-only git commands
(`log`, `diff`, `show`, `status`, `blame`) are fine.

**Checkpoint before risky or multi-step work:** `jj op log --no-graph --limit 1 -T
'id.short() ++ "\n"'` gives you the current operation ID. Note it before a sequence
of several operations, and `jj op restore <that-id>` is a single, exact way back if
anything goes sideways — verified more reliable than chaining `jj undo` calls (see
next point). This is what makes it reasonable to work through a multi-step sequence
without pausing after every single command — you have a known-good point to return
to, not license to skip verifying the final result.

**Verify after operations; on trouble, know when to stop.** Check `jj status`/
`jj log` actually show what you intended — don't assume success from exit code
alone. If something's off: one clearly-identified wrong step → just `jj undo` and
retry. Anything murkier (several operations deep, an unexpected conflict, not sure
what happened) → **stop, don't guess your way out** — tell the user what you
observe, suggest a concrete next step (ideally a specific `jj op restore <id>`), and
wait. **Never chain multiple `jj undo` calls expecting them to walk back N steps —
verified this doesn't work reliably** (undo itself creates operations, so a second
undo can target undo's own bookkeeping instead of the operation you actually meant,
and can even make an uncommitted file transiently disappear from disk — recoverable
via `jj op restore`, but confusing if you don't know to look). Full detail and the
exact reproduction: [safety-and-undo.md](references/safety-and-undo.md).

## Always use `--no-pager` and `--git`

Every command in examples below assumes `--no-pager` (prevents hanging on a pager in
a non-interactive shell). For `jj diff`, `jj show`, `jj log --patch`, and
`jj interdiff`, also pass `--git` — the default compact diff format is not reliably
parseable; the git-style format is.

```bash
jj --no-pager status
jj --no-pager diff --git
jj --no-pager log --limit 20 --revisions '<revset>' --template builtin_log_compact_full_description
```

## Reference index

- [references/splitting.md](references/splitting.md) — the preferred `jj split`
  workflow (file-level, non-interactive), placement flags, decision tree.
- [references/jj-hunk.md](references/jj-hunk.md) — hunk-level (sub-file) splitting
  with the `jj-hunk` companion tool, including jq-filtering to tame verbose output.
- [references/revsets.md](references/revsets.md) — the revset query language in full:
  symbols, operators, functions, string/date patterns, aliases, worked examples.
- [references/filesets.md](references/filesets.md) — the file-selection language used
  by `jj split`, `jj diff`, `jj file list`, etc.
- [references/workspaces.md](references/workspaces.md) — multiple working copies on
  one repo (`jj workspace add`), staleness, use for parallel agent work.
- [references/bookmarks.md](references/bookmarks.md) — bookmarks (branches), tracking,
  push safety checks, conflicts.
- [references/remotes-and-sync.md](references/remotes-and-sync.md) — clone/fetch/push
  mechanics, and a full two-clone divergent-change scenario reproduced and resolved
  end-to-end (bookmark conflicts vs. divergent changes — genuinely different things).
- [references/rebase-and-merge.md](references/rebase-and-merge.md) — `jj rebase`
  modes, merge commits, conflict markers and resolution, walked through on real
  examples.
- [references/safety-and-undo.md](references/safety-and-undo.md) — the full rewrite
  policy, `jj undo`/`jj op log`/`jj op restore`/`jj op revert`, the immutability
  nuance in detail.
- [references/advanced-operations.md](references/advanced-operations.md) — everything
  else, individually verified: `jj edit`, `next`/`prev`, `absorb`, `duplicate`,
  `parallelize`, `metaedit`, `revert`, `simplify-parents`, `run`, file operations,
  tags, sparse checkouts, and the full `jj op` subcommand set.
- [references/git-mapping.md](references/git-mapping.md) — Git → jj command table for
  fast lookup.
