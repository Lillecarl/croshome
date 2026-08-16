# Rebase, merging, and conflict resolution

`jj rebase` **rewrites history** (it changes commit IDs of everything it moves, and
often their descendants too). Per this skill's policy (see
[safety-and-undo.md](safety-and-undo.md)), don't run it unless the user asked for that
specific rebase. Creating a merge commit with `jj new`, by contrast, is pure addition
and always safe.

## Merge commits: `jj new`

```bash
jj --no-pager new -m 'merge: combine feature A and B' <rev1> <rev2>
```

Verified: this creates a new commit with both revisions as parents and moves `@` to
it. Any number of parents can be given (octopus merge). This is the safe, append-only
way to combine two lines of work — prefer it over rebasing one branch onto the other
when you just need to bring them together, not reorder history.

## `jj rebase`: three ways to choose *what* moves

Pick exactly one:

| Flag | Moves | Use when |
|---|---|---|
| `-s/--source <revset>` | the named revision(s) **and all descendants** | "take this commit and everything built on it" |
| `-b/--branch <revset>` | the whole "branch" relative to the destination: `(dest..X)::` | "take everything since this diverged from destination" (default if you specify neither) |
| `-r/--revision(s) <revset>` | **only** the named revision(s), not descendants (they get rebased onto whatever replaces their old parent) | surgically relocate one commit without dragging its descendants along |

## And *where* it goes — pick exactly one:

| Flag | Effect |
|---|---|
| `-o/--onto <revset>` (alias `-d/--destination`) | becomes a child of the given revision(s) — multiple revisions ⇒ merge |
| `-A/--insert-after <revset>` | inserted right after; existing children of the target get rebased onto the moved commit(s) |
| `-B/--insert-before <revset>` | inserted right before (i.e. onto the target's parents); the target and its descendants get rebased onto the moved commit(s) |

```bash
jj --no-pager rebase --source @ --destination main       # move @ and descendants onto main
jj --no-pager rebase --branch my-feature --destination main
jj --no-pager rebase --revisions <rev> --destination main   # only that one commit
jj --no-pager rebase --source L --destination K --destination M   # multiple destinations => merge
```

**Verified safety net:** jj refuses cyclic rebases outright. Trying to rebase an
ancestor onto its own descendant fails cleanly:
```
Error: Cannot rebase <commit> onto descendant <commit>
```
No `--force` exists to override this — it's a structural impossibility, not a policy
choice.

If a working-copy commit (`@` in some workspace) gets rebased away/abandoned as a side
effect, jj gives that workspace a fresh empty `@` automatically — this is general jj
behavior, not specific to rebase.

## Conflicts

A merge (via `jj new` or as a rebase side effect) can conflict if both sides changed
overlapping content. jj represents conflicts **as markers written directly into the
working-copy file** — verified exact format from the lab:

```
DEBUG = True
<<<<<<< conflict 1 of 1
%%%%%%% diff from: toyltmlr cc65b9a8 "docs: add usage section"
\\\\\\\        to: suzqkyrn fffd73b0 "edit main line X"
+MODE = "x"
+++++++ szxqumtw 3e4c56ca "edit main line Y"
MODE = "y"
>>>>>>> conflict 1 of 1 ends
```

`jj status` and `jj log` flag conflicted commits (`(conflict)` marker, and `jj status`
prints `Warning: There are unresolved conflicts at these paths: ...`).

### Resolving

**If the conflicted commit is `@` itself** (the common case right after a merge):
just edit the file to replace the markers with the resolved content. jj auto-snapshots
on the next command, and the conflict clears on its own:

```bash
# edit the file, remove markers, save
jj --no-pager status                 # confirms "no changes" / conflict warning gone
jj --no-pager resolve --list         # confirms "No conflicts found at this revision"
```

**If the conflicted commit is *not* `@`** (e.g. a merge deep in history that you're
not currently sitting on), you have two options, both of which touch history — treat
as a rewrite requiring the user's go-ahead unless they specifically asked you to fix
this conflict:
1. `jj new <conflicted-rev>` to create a working-copy commit on top with the same
   conflict, resolve it there, then `jj squash` the resolution back down into the
   conflicted commit.
2. `jj edit <conflicted-rev>` to resolve it in place directly (harder to review the
   diff of what you changed; see [safety-and-undo.md](safety-and-undo.md) for why
   `jj edit` in general needs explicit permission).

### Tools

```bash
jj --no-pager resolve --list          # list conflicted files in @ (or -r <rev>)
jj --no-pager resolve                 # open a configured 3-way merge tool
jj --no-pager resolve --tool :ours    # pick one side without a tool
jj --no-pager restore <path>          # discard local edits to a path, back to parent's version
```

`jj resolve`'s merge-tool integration only handles conflicts with exactly two sides
and a base (the common case). There's currently no built-in tool for directory/file
symlink-type conflicts — manual editing is the fallback.
