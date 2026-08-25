# Splitting: the preferred `jj split` workflow

This is the preferred way to turn a messy working copy (or any existing commit) into
several clean, logically-separated commits. It is preferred over ad-hoc `jj new` +
manual file shuffling because it's a single atomic operation, and preferred as the
*default* tool over `jj-hunk` because it needs no extra binary and is simplest at file
granularity. Reach for `jj-hunk` (see [jj-hunk.md](jj-hunk.md)) only when a single file
mixes concerns finer than whole-file.

## Why `jj split` is agent-safe (non-interactive mode)

`jj split` normally opens an interactive diff editor. **But if you pass one or more
fileset arguments, it runs entirely non-interactively**: the matched files go into the
first ("selected") commit, everything else into the second ("remaining") commit. No
editor, no TTY required. This was verified directly against the jj source
(`cli/src/commands/split.rs`): the diff selector only becomes interactive when
`--interactive`/`-i` is passed *or* the paths list is empty.

```bash
# Non-interactive: config.py goes in the first commit, everything else stays behind
jj --no-pager split src/config.py --message 'feat: add debug config flag'
```

Confirmed behavior in the lab: this produced two commits with no prompt at all.

**Do not run `jj split` with zero fileset arguments** — that opens an interactive
editor and will hang a non-interactive agent session. If you need finer-than-file
granularity, use [jj-hunk.md](jj-hunk.md) instead of forcing `--interactive`.

## Always pass `--message` to a non-interactive split

When the revision being split carries a description, jj needs descriptions for *both*
halves. With no `--message`, it opens a description editor even though the fileset
selection itself was non-interactive — and headless that editor dies loudly (verified:
a helix-wrapper panic, "Failed to edit description", nothing changed). Passing
`--message '...'` supplies the selected half's description and skips the editor
entirely. The remaining half keeps the original description.

## Basic shape

```bash
jj --no-pager split <fileset...> --message 'message for the selected part'
```

- Splits `@` by default. Use `--revision <rev>` to split a different (mutable)
  commit instead.
- Files matching `<fileset...>` → **first** commit ("Selected changes").
- Everything else → **second** commit ("Remaining changes"), which becomes the new
  child and — if you were splitting `@` — the new `@`.
- `--message` sets the description for the **first** (selected) commit only. The second
  commit keeps whatever description the original commit had (usually none, if you're
  splitting a WIP `@`).
- Splitting an **empty** commit is refused — there's nothing to split; use `jj new`.

### Which commit keeps the change ID, and where do bookmarks go?

These are two **different** identities, and — verified in the lab, this is
non-obvious — they end up on **different** commits after a plain split:

- The **first (selected) commit keeps the original change ID.** Confirmed twice in
  the lab: splitting a commit with change ID `wlkstozo` produced "Selected changes:
  `wlkstozo` ..." (same id) and "Remaining changes: `vnumpywx`" (a fresh id).
- **Any bookmark that pointed at the pre-split commit follows to the *second*
  (remaining) commit instead** — the one `@` moves to, i.e. the child. Confirmed in
  the lab: a bookmark on the pre-split commit ended up on the "Remaining changes"
  commit, not the "Selected changes" one, even though the selected commit is the one
  that kept the change ID. This is jj's actual default (`split.legacy-bookmark-behavior
  = true`, confirmed in jj's shipped config) — despite the "legacy" name it's what
  ships in 0.43/0.44. The rationale: a bookmark is meant to track "where development
  continues," which is the remaining commit (also the new `@`), not the historical
  chunk you just peeled off.
- If `split.legacy-bookmark-behavior = false` is configured, this flips: the bookmark
  stays with whichever commit kept the change ID (the first/selected one) instead.
  Don't assume either way in an unfamiliar repo — check with
  `jj config get split.legacy-bookmark-behavior` if it matters for the task at hand.
- Placement flags (`--onto`/`--insert-after`/`--insert-before`) change this further
  (the *selected* part is what gets relocated and gets the fresh change ID instead) —
  treat placement-flag splits as needing extra care about where names end up, and
  verify with `jj bookmark list` afterward if a bookmark was involved.

## Repeated splitting to build a narrative

Split repeatedly, peeling one logical concern off the front each time. `@` naturally
becomes the "everything not yet split out" commit after each step:

```bash
# Working copy has: src/schema.py (new), src/api.py (mixed), README.md (docs)
jj --no-pager split src/schema.py --message 'feat: add schema'
jj --no-pager split README.md --message 'docs: describe schema'
# Whatever's left (src/api.py) is still uncommitted in @ — finish with:
jj --no-pager commit --message 'feat: wire schema into api'
```

Or, if everything should end up committed via splits alone, keep splitting until the
last `jj split` leaves `@` empty automatically — a split's second commit is *only*
non-empty if there was something left unmatched.

## Fileset patterns

`<fileset...>` uses the same language as `jj diff`, `jj file list`, etc. — see
[filesets.md](filesets.md) for the full grammar. Common cases:

```bash
jj --no-pager split src/foo.py src/bar.py --message '...'      # exact files
jj --no-pager split src/ --message '...'                        # whole directory
jj --no-pager split 'glob:"*.md"' --message '...'                # glob
jj --no-pager split '~src/wip.py' --message '...'                # everything EXCEPT this file
```

## Placement flags: extracting to a different spot in the graph

By default the selected part stays where the original commit was, and the remaining
part becomes its child. Three flags relocate the *selected* part instead, leaving the
remaining part in place:

- `--onto <revset...>` (alias `--destination`) — the selected part is extracted into a
  new commit whose **parents are the given revision(s)**. Multiple revisions → a merge
  commit.
- `--insert-after <revset...>` — inserted directly after the given commit(s); their
  existing children get rebased onto the new commit.
- `--insert-before <revset...>` — inserted directly before the given commit(s)
  (i.e. onto their parents), and the given commits + descendants get rebased onto it.

Verified shape for `--onto` against an ancestor (`jjtandem3`/`jjonto` labs): splitting
`f4` from `@` with `--onto @-` left **two siblings under the base** — the parked
commit (`f4`) as a fresh child of base, and the remaining feature commit unchanged in
its original position. It does **not** insert into the mainline between them;
`--insert-before`/`--insert-after` are what splice into a line.

```bash
# Pull a fix out of @ and park it as its own branch off main
jj --no-pager split src/bugfix.py --message 'fix: null check' --onto main

# Splice it INTO the mainline right after main instead
jj --no-pager split src/bugfix.py --message 'fix: null check' --insert-after main
```

These flags make `jj split` a *rewrite* of graph structure beyond `@` (they can rebase
descendants) — treat them like `jj rebase` for the "don't do this unless asked" policy
in [safety-and-undo.md](safety-and-undo.md), unless you're only ever targeting `@`
itself with no other flags, which is always safe (it only ever appends/replaces the
one commit you named).

## Folding a peeled piece into an earlier commit

Split isolates; squash folds. To land missed changes from `@` inside an earlier
commit ([SKILL.md](../SKILL.md) has the short version):

```bash
jj split shared.txt --message 'the missed tweak'       # peels; sits at @-
jj squash --revision @- --use-destination-message      # folds into its parent
```

`--use-destination-message` keeps the destination's description and discards the
peeled one. Omit it (and omit `--message`) on a squash that empties a described
revision and jj opens the description editor — headless, a guaranteed panic.

You can skip the split entirely and move changes straight into the commit of your
choice. Whole files take one step (`--from` defaults to `@`; verified):

```bash
jj squash --from @ --into <rev> path/to/file
```

Hunk-level selection folds into the **parent** of its source revision in one step,
also without peeling ([jj-hunk.md](jj-hunk.md) has the spec format):

```bash
jj-hunk squash '{"files": {"src/foo.py": {"hunks": [0]}}, "default": "reset"}'
```

The split-then-fold tandem is still the shape when the destination is further up than
a parent: `jj-hunk squash` has no destination flag, and routing its selection through
`jj squash -i --tool=jj-hunk --into <rev>` does not work — verified in the lab that
the tool emits the wrong tree on the squash path and leaves the destination
conflicted.

## `--parallel`

Makes the two parts siblings (same parent) instead of parent → child:

```bash
jj --no-pager split src/a.py --message 'feat: a' --parallel
```

Use this when the two halves are genuinely independent and shouldn't imply an
ordering dependency (e.g. two unrelated fixes that happened to be edited together).

## Verifying a split

```bash
jj --no-pager log --limit 5 --revisions 'trunk()..@' --template builtin_log_compact_full_description --stat
jj --no-pager diff --git --revisions <rev>   # confirm each new commit's content
```

## Quick reference

```bash
jj --no-pager split <files...> --message 'msg'                          # file-level, non-interactive
jj --no-pager split <files...> --message 'msg' --parallel               # siblings instead of parent/child
jj --no-pager split <files...> --message 'msg' --onto <rev>             # relocate selected part
jj --no-pager split --revision <rev> <files...> --message 'msg'         # split a commit other than @
```
