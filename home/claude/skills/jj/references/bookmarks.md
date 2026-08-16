# Bookmarks (jj's term for branches)

A bookmark is a named pointer to a commit — like a Git branch, closer in spirit to a
Mercurial bookmark. The critical difference from Git: **there is no "current
branch."** Creating or being "on" a commit never moves a bookmark. Bookmarks only move
when the commit they point at is *rewritten* (e.g. by rebase) — jj tracks that via
change ID and follows along automatically — or when you move them explicitly.

## Creating, moving, deleting

```bash
jj --no-pager bookmark list                        # local bookmarks
jj --no-pager bookmark list --all                   # + remote-tracking state
jj --no-pager bookmark list --tracked               # only tracked bookmarks
jj --no-pager bookmark create <name> -r <rev>       # new bookmark at rev (default: @)
jj --no-pager bookmark set <name> -r <rev>          # create OR move
jj --no-pager bookmark move <name> --to <rev>       # move an EXISTING bookmark only (errors if it doesn't exist)
jj --no-pager bookmark move --from <rev> <name>     # move whichever bookmarks currently point at <rev>
jj --no-pager bookmark move <name> --to <rev> --allow-backwards  # required if <rev> isn't a descendant of the current target
jj --no-pager bookmark rename <old> <new>
jj --no-pager bookmark delete <name>                # deletes locally AND propagates the deletion on next push
jj --no-pager bookmark forget <name>                # deletes locally ONLY, does not propagate
```

By default `jj bookmark move` refuses to move a bookmark somewhere that isn't a
descendant of its current target (prevents accidentally rewinding a branch); pass
`--allow-backwards`/`-B` to force it. Note this flag belongs to `jj bookmark move`
specifically — `jj new` has **no** `--allow-backwards` flag at all (verified against
`jj new --help`); to branch off an old commit with `jj new` just name it directly,
no flag needed: `jj new <old-rev>`.

`create`/`set` at `@` are append-only-ish (safe by default). **`bookmark move`/`delete`
retarget or remove an existing pointer** — treat these like other rewrite-adjacent
operations: fine when you're clearly the one driving that bookmark's meaning (e.g.
moving your own feature bookmark forward after `jj commit`), but don't retarget or
delete a bookmark someone else is relying on (like a shared `main`) without being
asked. One-letter shortcut: `jj b` for `jj bookmark`.

## Remotes and tracking

jj records the **last-seen position** of each remote bookmark (like Git's
remote-tracking branches), reachable as `<name>@<remote>` (e.g. `main@origin`). A
local bookmark can be **tracked** against a remote bookmark of the same name — tracked
bookmarks stay in sync on fetch, and are what gets pushed by default.

```bash
jj --no-pager bookmark track <name> --remote=<remote>     # start tracking
jj --no-pager bookmark untrack <name> --remote=<remote>   # stop tracking (local bookmark unaffected)
```

`jj git clone` auto-tracks the default remote bookmark (verified against a real
GitHub clone: `main` came back already tracked, no extra step). Pushing a brand-new
local bookmark auto-tracks the resulting remote one. Everything else fetched is
untracked by default unless `remotes.<name>.auto-track-bookmarks` is configured — if
`jj new <bookmark>` fails right after a fetch with "did you mean
`<bookmark>@<remote>`", that's this: run `jj bookmark track <bookmark>
--remote=<remote>` first.

**Full push/fetch mechanics, multi-clone push rejection, and a complete verified
divergent-change walkthrough (two independent clones, real conflict, real
resolution):** see [remotes-and-sync.md](remotes-and-sync.md) — read it before
troubleshooting anything that involves more than one clone/remote of the same repo.

## Pushing

```bash
jj --no-pager git push --bookmark <name>     # push one bookmark (verified: NOT --allow-new — that flag doesn't exist)
jj --no-pager git push --all                 # push all bookmarks
jj --no-pager git fetch                      # pull remote state
jj --no-pager git fetch --remote <name>
```

Before moving/creating/deleting a remote bookmark, `jj git push` does three safety
checks (this is effectively `git push --force-with-lease`, always, by default — no
extra flag needed):
1. Contacts the remote and confirms its actual position matches jj's last-known
   record for that bookmark. Mismatch → push refused; run `jj git fetch` and resolve
   first.
2. The local bookmark must not itself be conflicted.
3. If the bookmark already exists on the remote, it must be tracked locally.

Pushing is not something to reach for unless the user asked you to publish work —
treat it like any other action visible to others (see the top-level agent
instructions on risky/hard-to-reverse actions).

## Conflicts

A bookmark can end up **conflicted** if it was moved differently, concurrently, in two
places (e.g. locally and on a remote you then fetched). `jj status` and `jj log` flag
this — `jj log` shows the bookmark name with a `??` suffix on each of its candidate
targets (e.g. `main??`). Looking the name up (`jj new main`) then errors because it
resolves to multiple revisions.

To resolve: pick a target and `jj bookmark move <name> --to <chosen-rev>`. If you want
to reconcile rather than just pick one side, `jj new <bookmark>` first creates a merge
of the conflicting targets, or `jj rebase` one side onto the other, then move the
bookmark onto the result.

A bookmark showing a trailing `*` (e.g. `main*`) means the local bookmark and its
remote-tracking record point to different places — a reminder that you may want to
push.

## `jj log` markers cheat sheet

- `main` — local bookmark, in sync with its remote (if any)
- `main*` — local bookmark differs from `main@<remote>` — push pending
- `main??` — conflicted bookmark, shown on each candidate target
- `main@origin` — the remote's last-known position (only shown when it differs from
  local)
