# `jj-hunk`: hunk-level (sub-file) splitting

`jj split <fileset>` (see [splitting.md](splitting.md)) only works at **file**
granularity non-interactively. When a single file mixes two concerns in the same
diff, you need hunk-level selection — that's what `jj-hunk` is for. It's a companion
CLI (`jj-hunk`, installed separately, e.g. `cargo install jj-hunk`), not a jj
subcommand.

Use `jj-hunk` only when file-level `jj split` genuinely isn't enough. If your changes
already land in separate files, prefer plain `jj split` — it's simpler and needs no
extra tool.

## `jj-hunk list` output is verbose — filter it

Each hunk in the JSON includes full `added`/`removed` text *and* surrounding
`context` (pre/post lines). On anything but a tiny diff this gets large fast. Two
ways to keep it manageable, both verified:

**1. Filter at the source with `--include` (preferred — avoids materializing the full
diff at all):**

```bash
jj-hunk list --include 'src/foo.py' | jq -c '.'
```

`--include`/`--exclude` accept globs and are repeatable — scope to exactly the
file(s) you're about to split before you even look at the output.

**2. If you already ran a full `jj-hunk list`, strip the bulky fields with `jq`**
instead of reading raw text/context:

```bash
# Structure only — path, hunk index, id, type. No content, no context.
jj-hunk list | jq -c '.files[] | {path, hunks: [.hunks[] | {index, id, type}]}'

# Cheapest possible overview — just file + hunk count, decide what to inspect next
jj-hunk list --files | jq -c '.'

# Only files you actually care about, after the fact
jj-hunk list | jq -c '.files[] | select(.path=="src/foo.py")'
```

**Recommended sequence for an agent:** run `jj-hunk list --files | jq -c '.'` first to
see which files have how many hunks, then `jj-hunk list --include '<that file>' | jq
-c '.'` to see the actual hunk content only for the file you're about to split. Avoid
piping a full unfiltered `jj-hunk list` through `jq` and reading all of it when you
only need one file — always prefer `--include` to cut the volume before it's
generated.

## Building a spec

Select hunks by 0-based `index` or by stable `id` (`hunk-<sha256>`, changes only if
the hunk's content changes), or use whole-file actions:

```json
{
  "files": {
    "src/foo.py": {"hunks": [0, 2]},
    "src/bar.py": {"action": "keep"},
    "src/baz.py": {"action": "reset"}
  },
  "default": "reset"
}
```

| Spec entry | Effect |
|---|---|
| `{"hunks": [0, 2]}` | only those hunk indices |
| `{"ids": ["hunk-..."]}` | only those hunks, by stable id (survives reordering) |
| `{"action": "keep"}` | whole file included |
| `{"action": "reset"}` | whole file excluded |
| top-level `"default": "reset"` | any file not listed is excluded (safer — explicit opt-in) |
| top-level `"default": "keep"` | any file not listed is included (convenient for "everything except this one file") |

`hunks` and `ids` merge if both given for the same file.

## Executing: `split` vs `commit` vs `squash`

| Command | Result |
|---|---|
| `jj-hunk split '<spec>' "msg"` | **Two** commits: matched hunks → first (with `msg`), rest → second (new empty-ish `@`). Everything ends up committed — mirrors plain `jj split`. |
| `jj-hunk commit '<spec>' "msg"` | **One** commit with only the matched hunks. Everything else stays **uncommitted** in the working copy for further editing. |
| `jj-hunk squash '<spec>'` | Matched hunks squashed into the **parent** of the source revision (`-r/--rev`, default `@`). The destination is always the parent — there is no flag for anything else. Opens no editor (no message needed — keeps parent's). For a farther destination, use file-level `jj squash --from <rev> --into <rev> <fileset>`, or peel first ([splitting.md](splitting.md)). |

```bash
jj-hunk split '{"files": {"src/utils.py": {"hunks": [0]}}, "default": "reset"}' \
  "refactor: extract helper"

jj-hunk commit '{"files": {"src/bug.py": {"action": "keep"}}, "default": "reset"}' \
  "fix: handle null case"

jj-hunk squash '{"files": {"src/tests.py": {"action": "keep"}}, "default": "reset"}'
```

Spec can also come from `--spec-file <path>` (JSON or YAML) or stdin (`cat spec.json |
jj-hunk commit - "msg"`) — prefer a spec file over an inline JSON blob once the spec
gets past two or three files, it's easier to get the quoting right.

## Worked example (mirrors `jj split`'s repeated-splitting pattern)

```bash
# 1. Cheap overview
jj-hunk list --files | jq -c '.'
# => {"files":[{"path":"src/utils.py","status":"modified","hunk_count":2}, ...]}

# 2. Look only at the file you're splitting
jj-hunk list --include 'src/utils.py' | jq -c '.files[]'

# 3. Peel off hunk 0 (say, a rename/cleanup) as its own commit
jj-hunk split '{"files": {"src/utils.py": {"hunks": [0]}}, "default": "reset"}' \
  "refactor: rename helper"

# 4. Whatever's left (hunk 1, plus any other untouched files) is still open —
#    finish with jj commit, or keep splitting/using jj-hunk again.
jj --no-pager commit -m 'feat: add new helper'
```

## Edge case: everything looks like one giant hunk

**Verified precisely (this is narrower than it might sound):** `jj-hunk` splits at
every unchanged-line boundary — two changes stay as **separate** hunks as long as at
least one unchanged line sits between them, *even if* a raw unified diff would have
merged them into one `@@` block for display (jj-hunk's hunking is finer-grained than
diff-context-window merging). Confirmed with a real test: a bugfix and a brand-new
function added directly below it, separated only by the two blank lines Python
convention already puts between top-level functions, still came back as **two**
separate hunks (`index 0`, `index 1`) — no extra separation needed.

The collapse only happens when the changed **lines themselves are truly contiguous**
— e.g. editing two lines that sit back-to-back with zero unchanged lines between them
(confirmed: editing lines 1 and 2 of a 3-line file, both changed, no blank line
between, produced exactly one `replace` hunk covering both — no way to select just
one of those two lines via hunk index). Options if you hit this, in order of
preference:
1. Just accept file-level granularity and use `jj-hunk commit`/`squash` with
   `{"action": "keep"}` for that whole file, splitting other files separately.
2. Add an unchanged (e.g. blank) line between the two concerns before diffing, if
   that's a reasonable code style choice anyway — confirmed this reliably splits them
   back into separate hunks.
3. Edit-then-list iteratively: commit the unambiguous parts first with `jj-hunk
   commit`, leave the rest uncommitted, keep editing, re-run `jj-hunk list` later once
   there's more separation.

## Direct `jj --tool` usage (rarely needed)

The `jj-hunk` subcommands above are convenience wrappers. For direct control (e.g.
scripting `jj split -i` itself):

```bash
echo '{"files": {"src/foo.py": {"hunks": [0]}}, "default": "reset"}' > /tmp/spec.json
JJ_HUNK_SELECTION=/tmp/spec.json jj --no-pager split -i --tool=jj-hunk -m "message"
```

Requires `~/.jjconfig.toml`:

```toml
[merge-tools.jj-hunk]
program = "jj-hunk"
edit-args = ["select", "$left", "$right"]
```

Prefer the plain `jj-hunk split/commit/squash` subcommands over this for normal use —
they don't require any jj config.

## Hunk types

| Type | Meaning |
|---|---|
| `insert` | pure addition |
| `delete` | pure removal |
| `replace` | removed + added at the same location |
