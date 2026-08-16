# Revsets: the query language for selecting commits

A **revset** is an expression that selects a set of commits (jj uses "revision" and
"commit" interchangeably). Nearly every jj command accepts one via `-r/--revision(s)`,
and many accept a bare positional revset. This is one of jj's biggest advantages over
Git — learn it well; it replaces a lot of `git log --grep`/`--author`/manual walking.

## Symbols

| Symbol | Meaning |
|---|---|
| `@` | The working-copy commit in the current workspace |
| `<workspace-name>@` | The working-copy commit in another workspace (see [workspaces.md](workspaces.md)) |
| `<name>@<remote>` | A remote-tracking bookmark/tag, e.g. `main@origin` |
| full or unique-prefix commit ID | That commit |
| full or unique-prefix change ID | That commit (change IDs are the stable jj identity) |

Symbol resolution priority when a bare word is ambiguous: **tag → bookmark → git ref →
commit/change ID.** Force a specific interpretation with `commit_id(x)` or a bookmark
function if needed (useful in scripts where a bookmark could shadow an intended ID).

Quote a symbol (`'"x-"'` from the shell) if it would otherwise parse as an expression
— e.g. the symbol literally named `x-` vs. "parents of `x`".

Only **visible** commits are searched by revsets unless you name a hidden commit
explicitly (by ID) — then its ancestors also become reachable for that query. See
"Hidden vs visible" below.

## Operators, strongest to weakest binding

Same-precedence infix operators associate left-to-right. Parentheses override.

| # | Operator | Meaning |
|---|---|---|
| 1 | `f(x)` | function call |
| 2 | `x-` | parents of `x` (can be empty) |
| | `x+` | children of `x` (can be empty) |
| 3 | `p:x` | string/date pattern, or a pattern alias named `p` |
| 4 | `x::` | descendants of `x`, including `x` |
| | `x..` | NOT ancestors of `x` (i.e. `~::x`) |
| | `::x` | ancestors of `x`, including `x` |
| | `..x` | ancestors of `x`, including `x`, excluding root |
| | `x::y` | descendants of `x` ∩ ancestors of `y` ("ancestry path" from x to y) |
| | `x..y` | ancestors of `y`, minus ancestors of `x` (like `git log x..y`) |
| | `::` | all visible commits |
| | `..` | all visible commits except root |
| 5 | `~x` | NOT in `x` |
| 6 | `x & y` | intersection |
| | `x ~ y` | `x` but not `y` |
| 7 | `x \| y` | union |

`x | y & z` = `x | (y & z)`. `x ~ y & z` = `(x ~ y) & z` (left-to-right at same tier).

**`..` does NOT distribute over `|` on its left side** — this is the #1 gotcha:
`(A|B)..` means "not an ancestor of A *and* not an ancestor of B" = `A.. & B..`, **not**
`A.. | B..`. If you want "everything after A or after B individually," write `A.. |
B..` explicitly.

### Operator examples (given `A -> {B, C} -> D` where D has parents B and C)

```
D-  ⇒ {C, B}          B-  ⇒ {A}           A-  ⇒ {root()}
D+  ⇒ {}               B+  ⇒ {D}           A+  ⇒ {B, C}
D:: ⇒ {D}               B:: ⇒ {D, B}        A:: ⇒ {D, C, B, A}
D.. ⇒ {}                B.. ⇒ {D, C}        A.. ⇒ {D, C, B}   (note: includes sibling C)
::D ⇒ {D, C, B, A, root()}         ::B ⇒ {B, A, root()}
B::D ⇒ {D, B}  (excludes C, unlike B..D)     B::C ⇒ {}  (C not a descendant of B)
B..D ⇒ {D, C}  (includes C, excludes B)      B..C ⇒ {C}
```

## Functions

Bracketed args are optional; some accept a keyword form (e.g. `remote_bookmarks(name,
remote=pat)`).

**Graph traversal**

| Function | Same as | Notes |
|---|---|---|
| `parents(x, [depth])` | `x-` at depth 1 | `parents(x, 3)` = `x---` |
| `children(x, [depth])` | `x+` at depth 1 | |
| `ancestors(x, [depth])` | `::x` | depth limits how far back |
| `descendants(x, [depth])` | `x::` | depth limits how far forward |
| `first_parent(x, [depth])` | — | merge-aware: only the first parent, not all |
| `first_ancestors(x, [depth])` | — | only follows first-parent chain (excludes side-branch history, like Git's mainline) |
| `reachable(srcs, domain)` | — | everything reachable from `srcs` via parent/child edges **without leaving `domain`**; great for "the stack I'm working on": `reachable(@, mutable())` |
| `connected(x)` | `x::x` | all commits connecting the members of `x` to each other |
| `heads(x)` | `x ~ ::x-` | commits in `x` with no descendant also in `x` |
| `roots(x)` | `x ~ x+::` | commits in `x` with no ancestor also in `x` |
| `fork_point(x)` | — | common ancestor(s) of everything in `x`; resolves to `x` itself if `x` is one commit |

**Sets / constants**

| Function | Meaning |
|---|---|
| `all()` | all visible commits (plus ancestors of anything explicitly named) |
| `none()` | empty set |
| `root()` | the virtual root commit (all-zero commit id, all-`z` change id) |
| `visible_heads()` | same as `heads(all())` |
| `working_copies()` | the `@` commit of every workspace |

**Lookup by identity**

| Function | Meaning |
|---|---|
| `change_id(prefix)` | commits with this change-ID prefix (errors on ambiguous prefix; multiple results if the change is divergent) |
| `commit_id(prefix)` | commits with this commit-ID prefix (errors on ambiguous prefix) |
| `bookmarks([pattern])` | targets of local bookmarks matching pattern |
| `remote_bookmarks([name], [remote=pat])` | targets of remote bookmarks (excludes `@git` bookmarks unless `remote="git"` or `"*"`) |
| `tracked_remote_bookmarks([...])` / `untracked_remote_bookmarks([...])` | subsets of the above |
| `tags([pattern])` / `remote_tags([...])` | tag targets |

**Filtering by content/metadata**

| Function | Meaning |
|---|---|
| `description(pattern)` | full commit message matches |
| `subject(pattern)` | first line of message matches |
| `author(pattern)` / `author_name(pattern)` / `author_email(pattern)` | author matches |
| `committer(pattern)` / `committer_name(pattern)` / `committer_email(pattern)` | committer matches |
| `author_date(pattern)` / `committer_date(pattern)` | date pattern match, see below |
| `mine()` | `author_email(exact-i:<your configured user.email>)` |
| `files(fileset-expression)` | commit touches matching paths — see [filesets.md](filesets.md). Quote patterns that would also parse as revset syntax, e.g. `files(".")`. |
| `diff_lines(text, [files])` / `diff_lines_added(...)` / `diff_lines_removed(...)` | commits whose diff contains a matching line |
| `empty()` | touches no files (includes content-free merges and `root()`) |
| `conflicts()` | has a file in conflicted state |
| `merges()` | has more than one parent |
| `divergent()` | change ID has multiple visible commits (conflicting rewrites) |
| `signed()` | cryptographically signed |

**Combinators / utilities**

| Function | Meaning |
|---|---|
| `present(x)` | `x`, or `none()` if any member of `x` doesn't exist (e.g. an unknown bookmark name) — use to avoid errors on optional refs |
| `coalesce(x, y, ...)` | first argument that isn't `none()` |
| `exactly(x, count)` | `x`, but errors unless it has exactly `count` members — good guard when a command needs precisely one commit |
| `bisect(x)` | binary-search helper (splits `x` roughly in half by descendant count) |
| `at_operation(op, x)` | evaluate `x` as of a past [operation](safety-and-undo.md) |

## String patterns

Used inside `description()`, `author()`, `bookmarks()`, etc. Bare `"string"` (no
prefix) defaults to `glob:`.

| Prefix | Meaning |
|---|---|
| `exact:"s"` | exact match |
| `glob:"s"` | shell-style wildcard |
| `regex:"s"` | regular expression, substring search |
| `substring:"s"` | plain substring |

Append `-i` for case-insensitive: `glob-i:"fix*jpeg*"`. Combine with `~`/`&`/`|`
inside the pattern itself: `bookmarks(~glob:"ci/*")`.

## Date patterns

Used by `author_date()`/`committer_date()`.

- `after:"<date>"` — at or after
- `before:"<date>"` — strictly before

Accepted date forms: `2024-02-01`, `2024-02-01T12:00:00[-08:00]`, `2 days ago`, `5
minutes ago`, `yesterday`, `yesterday 5pm`.

## Hidden vs visible commits

Most revsets only search **visible** commits (`jj log -r all()` shows exactly this
set). A commit is visible if it's reachable from an anonymous head recorded in the
current [view](safety-and-undo.md). Abandoned/rewritten commits become hidden — not
gone, just excluded from ordinary queries. If you name a hidden commit explicitly (by
commit ID, or via `at_operation()`), its ancestors also become searchable for that one
query.

## Built-in aliases (overridable in config)

- **`trunk()`** — the head of the default remote's main/master/trunk bookmark. Falls
  back to `root()` if nothing matches. **Verified gotcha:** in a repo with no remote
  (or no pushed main-like bookmark), `trunk()` = `root()`, even if you have a local
  `main` bookmark — see [safety-and-undo.md](safety-and-undo.md) for why this matters.
  Override per-repo if needed:
  ```toml
  [revset-aliases]
  'trunk()' = 'main'   # or wherever your actual trunk is, must resolve to exactly one commit
  ```
- **`immutable_heads()`** — defaults to `trunk() | tags() | untracked_remote_bookmarks()`.
- **`immutable()`** — `::(immutable_heads() | root())`. The set jj refuses to rewrite
  without `--ignore-immutable`.
- **`mutable()`** — `~immutable()`.
- **`visible()`** / **`hidden()`**.

Custom aliases go in `[revset-aliases]` in config, e.g.:
```toml
[revset-aliases]
'mine_recent()' = 'mine() & author_date(after:"2 weeks ago")'
```

## Worked examples

```bash
jj log -r @-                              # parent of the working copy
jj log -r ::@                             # everything reachable back to root — full history so far
jj log -r 'trunk()..@'                    # local work not yet on trunk (needs trunk() to resolve correctly — see gotcha above)
jj log -r 'remote_bookmarks()..'          # commits not on any remote
jj log -r 'reachable(@, mutable())'       # the whole mutable stack you're on, in any direction
jj log -r 'heads(all())'                  # every anonymous+bookmarked head currently visible
jj log -r 'empty()'                       # commits touching no files
jj log -r 'conflicts()'                   # commits with unresolved conflicts
jj log -r 'merges()'                      # merge commits
jj log -r 'description(glob:"fix:*")'     # commits whose message starts with "fix:"
jj log -r 'author(substring:"alice") & author_date(after:"yesterday")'
jj diff -r 'A::B'                         # diff over the ancestry path from A to B
jj diff -r 'A..B'                         # diff of everything B has that A doesn't (git-log-style range)
```

## Templating gotcha (not revset syntax, but adjacent)

`-T/--template` with a custom expression does **not** insert separators between
commits automatically — `-T 'change_id.short()'` over multiple commits prints them
concatenated with no newline. Add it yourself: `-T 'change_id.short() ++ "\n"'`.
Built-in templates (`builtin_log_compact_full_description`, etc.) already handle this.
