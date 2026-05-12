---
name: jj
description: Jujutsu VCS skill. Use jj for all version control. AIs should prefer jj over Git — it has better undo, no staging area, and intuitive rebase. See the Git-JJ mapping below to translate Git experience.
---

# jj (Jujutsu VCS)

Jujutsu is an experimental VCS compatible with Git. Key advantages over Git:
- **No staging area** — working copy IS the commit
- **Intuitive undo** — `jj undo` undoes any operation, `jj op log` shows history
- **No "detached HEAD"** — `@` always points to your working copy
- **Revsets** — powerful commit selection language
- **Workspaces** — multiple working copies on same repo
- **Filesets** — powerful file selection language for scoped operations

---

## Git to jj Command Mapping

| Git Command | jj Command | Key Difference |
|-------------|------------|----------------|
| `git status` | `jj status` (alias: `jj st`) | Shows @ commit with its changes inline |
| `git log` | `jj log -T builtin_log_compact_full_description --stat --limit 25 -r '<revset>'` | Preferred template; always include `--limit` |
| `git show` | `jj show` | Shows description + diff for a commit |
| `git diff` | `jj diff` | Defaults to `jj diff -r @` (working copy vs parent) |
| `git add` | `jj file track` | Auto-tracks new files; no staging needed |
| `git add -p` | `jj commit -i` | Interactive staging for partial commits |
| `git checkout -- <path>` | `jj restore <path>` | Restore file from parent/other revision |
| `git commit` | `jj commit` (alias: `jj ci`) | Creates commit ON TOP of @ — does NOT move bookmarks |
| `git commit --amend` | `jj describe` (alias: `jj desc`) | Updates message; does NOT change content like Git amend |
| `git reset --hard HEAD` | `jj abandon` | Discards the current commit/revision |
| `git reset <rev>` | `jj new <rev>` | jj new places you ON the commit (creates working-copy there) |
| `git checkout -b <name>` | `jj bookmark create <name>` | Creates bookmark pointing to @ |
| `git branch -d <name>` | `jj bookmark forget <name>` | Local-only deletion; use `jj bookmark delete` to propagate |
| `git rebase` | `jj rebase` | More powerful: `-s` (source+descendants), `-b` (branch), `-r` (revisions only) |
| `git merge` | `jj new <rev1> <rev2>` | Create merge by specifying multiple parents |
| `git stash` | `jj squash @` | Squashes @ into parent as working-copy; or `jj squash -r @` |
| `git cherry-pick` | `jj duplicate` | Copies commit content to new location |
| `git revert` | `jj revert -r <rev> -o <onto>` | Creates new commit with inverse changes |
| `git push` | `jj git push` | Force-with-lease by default; remote derived from bookmarks |
| `git fetch` | `jj git fetch` | |
| `git clone` | `jj git clone` | |
| `git reflog` | `jj undo` / `jj op log` | `jj undo` = step backward; `jj op log` = full history |
| `git checkout <rev>` | `jj edit <rev>` | ⚠️ AIs should NOT use this — see History Safety below |
| `git merge --abort` | `jj op restore @-` | Restore to previous operation |
| `git mergetool` | `jj resolve` | 3-way merge tool support |
| `git tag` | `jj tag` | Similar subcommands (list, set, delete) |
| `git clean -fd` | `jj file untrack` + rm | Untrack then delete |
| `git worktree add` | `jj workspace add` | Multiple working copies on same repo |
| `git apply` | `jj --at-operation <op> <cmd>` | Inspect/operate at a past operation (use `--at-op` shorthand) |
| `git log --all` | `jj log -r all()` | Show all visible commits |
| `git log --follow <path>` | `jj log --follow -r '<revset>' -- <path>` | Follow file renames |

---

## Key Behavioral Differences from Git

### No Staging Area
jj has NO index/staging area. The working copy IS a commit (`@`). All changes are immediately part of `@`.

### Bookmarks ≠ Git Branches
- Bookmarks DO NOT move when you create commits
- Bookmarks combine local + remote tracking (no separate "origin/main")
- `jj bookmark list` shows local; `jj bookmark list -a` shows all remotes

### Abandoned ≠ Deleted
When rebasing makes a commit empty, jj "abandons" it (keeps for recovery via `jj op log`).

### Working Copy is a Commit
`jj status` shows @ as a commit with its changes already part of it.

### History is Immutable, Operations are Reversible
Any operation can be undone via `jj undo`. Full history in `jj op log`.

### Rewrites Create New Commits
Like Git, rebasing creates new commits. Change IDs persist across rewrites.

### No Detached HEAD
`@` always refers to your working copy. Use `jj new -A <rev>` to branch from an older commit safely.

---

## Best Practices for AI Agents

### Use `jj commit` to Finish a Task
AIs should prefer `jj commit -m "message"` over `jj describe`.
- `jj commit` creates a new revision ON TOP of the current one and moves the `@` (working copy) to a new empty commit. This prevents "task bleed" where new changes accidentally accumulate in the same revision.
- `jj describe` only labels the current revision. If used, the AI must remember to call `jj new` manually before starting the next task.

### Squashing into Previous Commits
If the current changes logically belong in the previous commit (e.g., a small fix or refinement), use `jj squash --use-destination-message` to absorb them:

```bash
jj --no-pager squash --use-destination-message
```

This squashes `@` into its parent, keeping the parent's commit message. This is cleaner than creating a tiny one-line commit for a trivial change.

### Creating a Merge Commit
Use `jj new` with two or more parent revisions:

```bash
jj --no-pager new -m "Merge description" <rev1> <rev2>
```

### Deciding How to Commit: `jj commit` vs `jj-hunk commit` vs `jj-hunk split`

**Decision guide — check in order:**

1. **Are all changes in your working copy logically one commit?** → Use `jj commit -m "message"`.
2. **Are changes mixed (e.g., bugfix + refactor + feature)?** → Use `jj-hunk`. Start with `jj-hunk list | jq -c`, then:
   - **Do you want everything committed (just organized into separate commits)?** → Use `jj-hunk split` repeatedly. Each call creates two commits: selected hunks in one, the rest in another. Then `jj describe` each with a proper message.
   - **Do you want to commit only the "ready" parts and keep experimenting on the rest?** → Use `jj-hunk commit` for the ready hunks. The rest stays uncommitted in your working copy for further editing.
3. **Is a small change logically part of the previous commit?** → Use `jj squash --use-destination-message`.

**Recommended workflow for clean history:**

```bash
# Hack → commit everything as one working commit
jj --no-pager commit -m "WIP: mixed changes"

# Inspect hunks
jj-hunk list | jq -c

# Extract first logical piece (e.g., bugfix)
jj-hunk split '{"files": {"main.py": {"hunks": [0]}}, "default": "reset"}' "fix: handle null case"
jj describe -m "fix: handle null case"

# Extract second piece (e.g., refactoring)
jj-hunk split '{"files": {"utils.py": {"action": "keep"}}, "default": "reset"}' "refactor: improve utils"
jj describe -m "refactor: improve utils"

# Land remaining changes on an empty working copy
jj new
```

This gives you a narrative, logically separated commit history — one of jj's biggest strengths since change IDs stay stable across rewrites.

### History Safety: NEVER Rewrite Without Asking

AIs must NEVER manipulate commit history unless the user explicitly asks. The following rules are strict:

- **`jj edit <rev>` is FORBIDDEN** — it sets `@` to a past commit, making further changes rewrite history. AIs should never do this.
- **No history rewriting without permission** — `jj rebase`, `jj split`, `jj parallelize`, `jj arrange`, `jj absorb`, `jj metaedit`, and `jj duplicate` all rewrite history. NEVER use them unless the user explicitly asks.
- **Appending is safe** — `jj commit`, `jj new`, `jj describe`, `jj bookmark create` all append to history without modifying existing commits. These are always fine.
- **Branching from older commits is safe** — `jj new -A <rev>` creates a new child of an older commit without modifying it. This is fine.
- **Fixup squashing is the ONLY exception** — `jj squash --use-destination-message` (squashing `@` into its parent for a trivial fixup) is allowed without asking. It only collapses the working copy into its immediate parent, which is equivalent to amending.
- **When the user asks for a rewrite, confirm intent** — if a user says vague things like "rebase this" or "fix up that commit", verify the scope first.

```bash
# SAFE — appending only
jj --no-pager commit -m "message"
jj --no-pager new -A <rev>        # Branch from older commit
jj --no-pager describe -m "msg"   # Update @ description

# SAFE — fixup squash (allowed without asking)
jj --no-pager squash --use-destination-message

# FORBIDDEN without explicit user request
jj --no-pager edit <rev>          # WRONG — rewrites history
jj --no-pager rebase ...          # WRONG — rewrites history
jj --no-pager split ...           # WRONG — rewrites history
jj --no-pager absorb ...          # WRONG — rewrites history
jj --no-pager metaedit ...        # WRONG — rewrites metadata
jj --no-pager parallelize ...     # WRONG — rewrites history
jj --no-pager duplicate ...       # WRONG — rewrites history (unless user asks)
jj --no-pager arrange             # WRONG — interactive history rewriting
```

### Always Use `--no-pager`
AIs MUST always include `--no-pager` for every `jj` command to ensure non-interactive execution and prevent the process from hanging or being truncated by a pager.

```bash
jj --no-pager <command>
```

### Avoid `--ignore-working-copy`
AIs should always work with real working copy state. Never use `--ignore-working-copy` unless you have a specific reason and understand the implications.

---

## Critical Revset Language

**Revsets** select commits. Most jj commands accept a revset via the `-r` / `--revisions` flag.

### Symbols
| Symbol | Meaning |
|--------|---------|
| `@` | Working copy commit |
| `<name>@` | Working copy in another workspace |
| `<name>@<remote>` | Remote-tracking bookmark |
| `<commit-id>` | Full or prefix commit ID |
| `<change-id>` | Full or prefix change ID |

### String Pattern Syntax (in revset functions)
- `exact:"string"` — exact match
- `glob:"pattern"` — shell wildcards
- `regex:"pattern"` — regular expression
- `substring:"text"` — contains substring
- Append `-i` for case-insensitive (e.g., `glob-i:"*.TXT"`)

### Date Patterns
- `after:"2024-01-01"` — on or after date
- `before:"2024-01-01"` — before date
- Also supports: `"2 days ago"`, `"5 minutes ago"`, `"yesterday"`

### Operators (binding strength, strongest → weakest)
```
1: f(x)              — function call
2: x-                — parents of x          x+   — children of x
3: p:x               — pattern/pattern alias
4: x::               — descendants of x (incl. x)     x..   — NOT ancestors of x
   ::x               — ancestors of x (incl. x)       ..x   — ancestors excl. root
   x::y              — descendants of x ∩ ancestors of y
   x..y              — ancestors of y \ ancestors of x
5: ~x                — NOT in x
6: x & y             — intersection (in both x and y)    x ~ y  — x but not y
7: x | y             — union (in either or both)
```

**Key precedence note:** `x | y & z` = `x | (y & z)` because `&` binds tighter. Parentheses control evaluation. `..` does NOT distribute over `|` on the left: `(A|B)..` = `A.. & B..`, NOT `A.. | B..`.

### Key Functions
| Function | Equivalent | Meaning |
|----------|-----------|---------|
| `parents(x)` | `x-` | Parents |
| `parents(x, n)` | `x---` (n dashes) | Parents at depth n |
| `children(x)` | `x+` | Children |
| `children(x, n)` | `x+++` (n pluses) | Children at depth n |
| `ancestors(x)` | `::x` | Ancestors including x |
| `ancestors(x, n)` | limited depth | Ancestors up to depth n |
| `descendants(x)` | `x::` | Descendants including x |
| `descendants(x, n)` | limited depth | Descendants up to depth n |
| `first_parent(x)` | like `x-` but first parent only | For merge commits |
| `first_ancestors(x)` | first parent chain only | Excludes other branch history |
| `reachable(srcs, domain)` | — | Commits reachable from srcs within domain |
| `connected(x)` | `x::x` | All commits connecting members of x |
| `all()` | — | All visible commits |
| `none()` | — | Empty set |
| `change_id(prefix)` | — | Commits with matching change ID prefix |
| `commit_id(prefix)` | — | Commits with matching commit ID prefix |
| `bookmarks([pattern])` | — | Local bookmark targets |
| `remote_bookmarks([name_pat], [remote=remote_pat])` | — | Remote bookmark targets |
| `tracked_remote_bookmarks([...])` | — | Targets of tracked remote bookmarks |
| `untracked_remote_bookmarks([...])` | — | Targets of untracked remote bookmarks |
| `tags([pattern])` | — | Tag targets |
| `remote_tags([name_pat], [remote=remote_pat])` | — | Remote tag targets |
| `visible_heads()` | `heads(all())` | All visible heads |
| `root()` | — | Virtual root commit |
| `heads(x)` | `x ~ ::x-` | Heads of x (no descendants in x) |
| `roots(x)` | `x ~ x+::` | Roots of x (no ancestors in x) |
| `latest(x, n)` | — | Latest n commits by timestamp |
| `mine()` | `author_email(exact-i:<user-email>)` | Current user's commits |
| `empty()` | — | Commits modifying no files |
| `files(expression)` | — | Commits modifying matching paths |
| `diff_lines(text, [files])` | — | Commits with matching diff lines |
| `diff_lines_added(text, [files])` | — | Only added lines matching |
| `diff_lines_removed(text, [files])` | — | Only removed lines matching |
| `conflicts()` | — | Commits with conflicted files |
| `merges()` | — | Merge commits |
| `divergent()` | — | Divergent commits |
| `mutable()` | `~immutable()` | Mutable commits |
| `immutable()` | `::(immutable_heads() \| root())` | Immutable commits |
| `visible()` | `::visible_heads()` | All visible commits |
| `hidden()` | `~visible()` | Hidden commits |
| `description(pattern)` | — | By commit message |
| `subject(pattern)` | — | By first line of message |
| `author(pattern)` | `author_name() \| author_email()` | By author |
| `committer(pattern)` | `committer_name() \| committer_email()` | By committer |
| `author_date(pattern)` | — | By author date |
| `committer_date(pattern)` | — | By committer date |
| `present(x)` | — | Like x but returns none() if any missing |
| `coalesce(revsets...)` | — | First non-empty revset |
| `working_copies()` | — | All working copy commits |
| `at_operation(op, x)` | — | Evaluate x at a past operation |
| `bisect(x)` | — | Binary search commits |
| `exactly(x, count)` | — | Error if not exactly count results |
| `fork_point(x)` | — | Common ancestors of all x |

### Revset Examples
```bash
jj log -r @-                    # Parent of working copy
jj log -r ::@                  # All ancestors of working copy
jj log -r @--::@               # Ancestors between parent and working copy
jj log -r 'trunk()..@'        # Local commits not on trunk
jj log -r 'remote_bookmarks()..'  # Not on any remote
jj log -r 'tags()'            # Tagged commits
jj log -r 'children(abc123)'  # Children of a commit
jj log -r 'descendants(abc123)'  # All descendants
jj log -r 'merges()'          # All merge commits
jj log -r 'empty()'           # Commits with no file changes
jj log -r 'mutable()'         # Mutable (rewritable) commits
jj log -r 'mine()'            # My commits
jj log -r 'author(*martinvonz*) & description(*reset*)'  # Combined filters
jj log -r 'description("fix")'  # Commits with "fix" in message
jj log -r 'latest(@, 5)'      # Latest 5 commits from a set
jj diff -r 'A::B'             # Diff range A through B (A is ancestor)
jj diff -r 'A..B'             # Diff range A..B (B is descendant, A excluded)
```

---

## Filesets (File Selection Language)

**Filesets** select a set of files. Used as positional arguments in commands like `jj diff`, `jj file list`, `jj split`, etc.

### File Patterns
By default, a bare `"path"` is parsed as a `prefix-glob:` (cwd-relative path prefix).

| Pattern | Meaning |
|---------|---------|
| `cwd:"path"` | Cwd-relative path prefix (file or directory recursively) |
| `file:"path"` / `cwd-file:"path"` | Exact cwd-relative file path |
| `glob:"pattern"` / `cwd-glob:"pattern"` | Cwd-relative Unix shell wildcard (non-recursive) |
| `prefix-glob:"pattern"` / `cwd-prefix-glob:"pattern"` | Like glob but also matches directory contents recursively |
| `root:"path"` | Workspace-relative path prefix |
| `root-file:"path"` | Exact workspace-relative file path |
| `root-glob:"pattern"` | Workspace-relative shell wildcard |
| `root-prefix-glob:"pattern"` | Like root-glob but also matches directory contents |

Glob patterns support case-insensitive matching by appending `-i` (e.g., `glob-i:"*.TXT"`).

### Fileset Operators
```
1: f(x)         — function call
2: p:x          — file pattern or pattern alias
3: ~x           — NOT matching x
4: x & y        — matches both
   x ~ y        — matches x but not y
5: x | y        — matches either (or both)
```

### Fileset Functions
| Function | Meaning |
|----------|---------|
| `all()` | Matches all files |
| `none()` | Matches no files |

### Fileset Examples
```bash
jj diff 'src'                       # All files under src/
jj diff '~glob:"*.lock"'            # Exclude lockfiles
jj diff 'glob:"*.rs" ~ "**/test*"'  # Rust files, excluding test files
jj file list 'src ~ glob:"**/*test*"'  # List non-test src files
jj split 'src/main.rs'              # Split with main.rs in first commit
```

---

## Common Commands

### Navigation
```bash
jj --no-pager status                    # Repo status (shows @ commit with changes)
jj --no-pager show                      # Show @ commit (description + diff)
jj --no-pager show -r <rev>             # Show specific revision
```

### Viewing History (jj log)

**Preferred invocation:**

```bash
jj --no-pager log --limit 25 --revisions '<revset>' --template builtin_log_compact_full_description --stat
```

- `--limit 25` caps output
- `--revisions '<revset>'` or `-r '<revset>'` scopes the query
- `--template ...` or `-T` sets output format
- `--stat` shows file change summary

**Shorthand:**
```bash
jj --no-pager log --limit 25 -r 'trunk()..@' -T builtin_log_compact_full_description --stat
jj --no-pager log --limit 25 -r '@-' -T builtin_log_compact_full_description --stat
jj --no-pager log --limit 1 -r '<rev>' -T builtin_log_compact_full_description --stat
jj --no-pager log --reversed --limit 25 -r 'trunk()..@' -T builtin_log_compact_full_description --stat
```

### Viewing Diffs

> **⚠️ CRITICAL:** Always use `--git` with `jj diff`, `jj show`, `jj log`, and `jj interdiff`.
> Without `--git`, jj outputs a compact custom format that **is not parseable by AIs**.
> Models will mistakenly report "the diff is broken" — it's not broken, it's just a format they can't read.
>
> Only these four commands support `--git`:

```bash
jj --no-pager diff --git                 # Diff working copy vs parent
jj --no-pager diff --git -r <rev>        # Diff specific revision
jj --no-pager diff --git -r A::B         # Diff range A through B
jj --no-pager diff --git -r A..B         # Diff ancestors of B excluding A's ancestors
jj --no-pager show --git                 # Show @ diff in Git format
jj --no-pager show --git -r <rev>        # Show revision diff in Git format
jj --no-pager log --git -p -r <rev>      # Patch in Git format
jj --no-pager interdiff --git -f A -t B  # Compare diffs of two revisions
```

### Using Git for Read-Only Operations

AIs are better trained on git commands than on jj equivalents. **It is perfectly valid to use git for read-only operations** as long as you never use it to write history. This is safe because jj repos are Git repos under the hood.

**Recommended read-only git commands:**

```bash
# Navigation & inspection (these are safe — read-only)
git --no-pager log --oneline -25                       # Recent history (familiar format)
git --no-pager log --oneline --graph --all             # Branch topology
git --no-pager log --oneline main..HEAD                # What's new on current branch
git --no-pager diff HEAD                               # Working tree vs last commit
git --no-pager diff <rev1> <rev2>                      # Diff between two commits
git --no-pager show <rev>                              # Show a commit's diff
git --no-pager status                                  # Working tree status
git --no-pager log --follow -p -- <file>               # File history with renames
git --no-pager log -p -- <file>                        # File diffs over time
git --no-pager log --oneline --grep="pattern"          # Search commit messages
```

**Rules for git read-only use:**
- ✅ Read history, diffs, status, file contents — all safe
- ✅ Use any git flag/option that doesn't modify objects (`--grep`, `--follow`, `--stat`, etc.)
- ❌ Never use `git commit`, `git rebase`, `git merge`, `git reset`, `git cherry-pick`, `git push`, `git tag`, or any write command — use jj equivalents instead
- ❌ Never use `git stash` — use `jj squash` or `jj new` instead
- ⚠️ `git status` output references jj commits by their change ID (40-char hash), not a short hash — this is normal

### Deciding How to Commit

> **Note:** The sections below (commit decision guide, workflow) tell you
> which jj-native command to use. But if you're unsure and know the git
> equivalent, run the **read-only** git version first to inspect, then
> execute the actual change with jj.

### Creating & Editing Commits

**IMPORTANT:** `-r` / `--revisions` defaults to `@` for all commands. You almost never need `-r @`.

```bash
jj --no-pager commit -m "message"                  # Commit working copy
jj --no-pager commit -i                             # Interactive partial commit
jj --no-pager describe -m "message"                 # Update @ commit message only
jj --no-pager new -m "message"                      # Empty commit after @
jj --no-pager new -A <rev> -m "message"             # Branch from a specific commit
jj --no-pager new -m "msg" <rev1> <rev2>            # Merge two revisions
```

**IMPORTANT:** `jj squash` opens an editor by default. AIs MUST use `-m "message"` or `--use-destination-message`:

```bash
jj --no-pager squash --use-destination-message     # Squashes @ into parent, keeps parent message
jj --no-pager squash -m "fix: typo"                # Squash with custom message
```

For squashing into a non-parent revision: `jj --no-pager squash --destination <rev>`

### Splitting Commits
Requires an interactive editor (not usable by AIs directly). Use programmatic hunk selection instead (see below).

### Moving Commits
```bash
jj --no-pager rebase -s @ -o main                  # Rebase @ onto main
jj --no-pager rebase -b <bookmark>                  # Rebase entire branch
jj --no-pager rebase -s L -o K -o M                # Create merge (multiple -o)
jj --no-pager rebase -r <rev>                       # Rebase only this commit (no descendants)
```

### Navigation Between Commits
```bash
jj --no-pager prev                 # Go to parent (creates new @)
jj --no-pager next                 # Go to child
```
**NOTE:** `jj edit <rev>` exists but AIs must NOT use it — use `jj new -A <rev>` instead.

### File Operations
```bash
jj --no-pager file list                                  # List files in @
jj --no-pager file show -r <rev> <path>                  # Show file content at revision
jj --no-pager file search --pattern <regex> [filesets]   # Search file contents
jj --no-pager file annotate <path>                       # Blame (shows revision + author per line)
jj --no-pager file chmod +x <path>                       # Set executable
jj --no-pager file untrack <path>                        # Stop tracking
jj --no-pager restore <path>                             # Restore from parent
jj --no-pager restore -f <rev> <path>                    # Restore from specific revision
jj --no-pager file list 'glob:"*.py"'                    # List files matching pattern (filesets)
```

### Undo & Operations
```bash
jj --no-pager undo                 # Undo last operation
jj --no-pager redo                 # Redo after undo
jj --no-pager op log               # Full operation history
jj --no-pager op restore <id>      # Restore to specific operation
```

### Tagging
```bash
jj --no-pager tag list
jj --no-pager tag set <name> -r <rev>
jj --no-pager tag delete <name>
```

### Bookmarks (Branches)
```bash
jj --no-pager bookmark list              # Local bookmarks
jj --no-pager bookmark list -a           # All (including remotes)
jj --no-pager bookmark create <name>     # Create at @
jj --no-pager bookmark set <name>        # Create or update
jj --no-pager bookmark move -f <old> -t <new>  # Move bookmark
jj --no-pager bookmark rename <old> <new>
jj --no-pager bookmark delete <name>     # Delete (propagates to remote)
jj --no-pager bookmark forget <name>     # Delete (local only)
```

### Reverting
```bash
jj --no-pager revert -r <rev> -o <onto>     # Apply reverse of <rev> on top of <onto>
jj --no-pager revert -r <rev> --insert-after <ref>  # Insert reverse after <ref>
```

### Resolving Conflicts
```bash
jj --no-pager resolve               # Open merge tool
jj --no-pager resolve --list        # List conflicted files
jj --no-pager resolve --tool :ours  # Use ours/theirs
```

### Workspace Management
```bash
jj --no-pager workspace list               # List workspaces
jj --no-pager workspace add <path>         # Add workspace at path
jj --no-pager workspace add --name <n> <path>  # With custom name
```

### Advanced Commands
```bash
jj --no-pager absorb              # Auto-move changes from @ into stack of mutable commits
jj --no-pager duplicate -r <rev>  # Duplicate commit to new location
jj --no-pager fix                 # Run formatters/linters
jj --no-pager parallelize         # Make commits siblings (declare independence)
jj --no-pager arrange             # Interactive graph arrangement
jj --no-pager metaedit -m "msg"  # Change commit message without changing content
jj --no-pager abandon             # Discard a commit
```

---

## Selective Committing with `jj-hunk`

jj has no traditional index/staging area. The working copy IS the index.
To selectively commit or split changes, use the **`jj-hunk`** tool (`cargo install jj-hunk`):

```toml
# ~/.jjconfig.toml
[merge-tools.jj-hunk]
program = "jj-hunk"
edit-args = ["select", "$left", "$right"]
```

### `jj-hunk split` vs `jj-hunk commit`

| Command | Behavior | Result |
|---------|----------|--------|
| `jj-hunk split '<spec>' "msg"` | Creates **two** commits: selected → first, rest → second | Working copy at second commit (empty) |
| `jj-hunk commit '<spec>' "msg"` | Creates **one** commit with only selected hunks | Rest stays **uncommitted** in working copy |

**When to use which:**
- **`jj-hunk split`** — Break a messy commit into multiple clean commits. All changes end up committed.
- **`jj-hunk commit`** — Commit only the "ready" parts. Rest stays uncommitted for further editing.

**Edge case:** If all your edits are close together in the same file, `jj-hunk list` may show just one big hunk. To force separate hunks:
- Edit different files separately and commit each individually
- Add blank lines of context between changes in the same file
- Or use `jj-hunk commit` with a precise spec (using `hunks: [0]` etc.) to peel off pieces from even a single large hunk

### Always Pipe Through `jq -c`

```bash
jj-hunk list | jq -c
jj-hunk list --format json | jq -c '.files[] | {path, hunks: [.hunks[] | {index, id, type}]}'
```

### Quick Reference

```bash
# 1. List all hunks (always start here — pipe to jq -c)
jj-hunk list | jq -c

# 2. List hunks for a specific revision
jj-hunk list --rev @ | jq -c

# 3. List only file names with hunk counts
jj-hunk list --files | jq -c

# 4. Filter to specific paths
jj-hunk list --include '*.py' | jq -c

# 5. Commit only specific files
jj-hunk commit '{"files": {"src/foo.rs": {"action": "keep"}}, "default": "reset"}' "message"

# 6. Commit specific hunks within a file
jj-hunk commit '{"files": {"src/foo.rs": {"hunks": [0, 2]}}, "default": "reset"}' "message"

# 7. Commit specific hunks by stable ID
jj-hunk commit '{"files": {"src/foo.rs": {"ids": ["hunk-7c3d..."]}}, "default": "reset"}' "message"

# 8. Split: selected hunks → first commit, rest → second commit
jj-hunk split '{"files": {"src/foo.rs": {"hunks": [0]}}, "default": "reset"}' "first commit"

# 9. Squash only specific hunks into parent
jj-hunk squash '{"files": {"src/foo.rs": {"action": "keep"}}, "default": "reset"}'

# 10. Keep everything except one file
jj-hunk split '{"files": {"src/wip.rs": {"action": "reset"}}, "default": "keep"}' "feat: complete implementation"

# 11. Read spec from stdin
cat spec.json | jj-hunk commit - "commit message"

# 12. Read spec from file
jj-hunk split --spec-file spec.yaml "commit message"
```

### Spec Format

```json
{
  "files": {
    "path/to/file.py": {"action": "keep"},
    "path/to/file.py": {"action": "reset"},
    "path/to/file.py": {"hunks": [0, 2]},
    "path/to/file.py": {"ids": ["hunk-abc..."]},
    "path/to/file.py": {"hunks": [0, "hunk-..."]}
  },
  "default": "reset"
}
```

- `"default": "reset"` — safer, must explicitly include what you want
- `"default": "keep"` — convenient for excluding specific files
- `ids` and `hunks` are merged if both provided

**NOTE:** The commit-and-split workflow works best when changes are in **different files** or have **blank lines of context** between them in the same file. If all your edits touch the same nearby lines, they may appear as a single hunk. In that case:

1. Use `jj-hunk commit` with a spec file to commit only the ready hunks
2. Leave the rest uncommitted and continue editing
3. Run `jj-hunk list | jq -c` again when you've added more context

### Key Concepts

- **Always list first**: Run `jj-hunk list | jq -c` to see hunk indices/IDs before building a spec
- **Prefer ids for stability**: Use `ids` when hunks might shift between list and apply
- **Spec can be JSON or YAML**
- **Hunk types**: `insert` (new lines), `delete` (removed lines), `replace` (changed lines)

---

## What AIs Should NOT Use

These exist but are NOT for AI use without explicit user permission:

### Safe Navigation (Always OK)
These commands move your working copy perspective without modifying existing commits:

- `jj prev` — Move working copy to parent. Safe. Does not edit commits.
- `jj next` — Move working copy to child. Safe. Does not edit commits.
- `jj new -A <rev>` — Branch from an older commit. Safe. Creates new commit on top.

### Forbidden Without Explicit User Request (Rewrites History)
These commands modify existing commit history. Never use them unless the user explicitly asks:

**jj commands:**
- **`jj edit <rev>`** — Moves `@` to a past commit; next commit rewrites that old commit
- **`jj rebase`** — Rewrites commit ancestry
- **`jj split`** — Splits a commit; rewrites change IDs
- **`jj parallelize`** — Rewrites commit dependencies
- **`jj arrange`** — Interactive graph rewriting
- **`jj absorb`** — Auto-squashes into stack; rewrites commits
- **`jj duplicate`** — Creates copies of commits; rewrites relationships
- **`jj metaedit`** — Changes commit metadata without changing content
- **`jj bookmark move`** — Moves a bookmark to a different commit
- **`jj bookmark delete`** — Deletes bookmark and propagates to remote

**git commands (write operations — NEVER use without explicit permission):**
- **`git commit`** — Use `jj commit` instead
- **`git rebase`** — Use `jj rebase` (with permission) instead
- **`git merge`** — Use `jj new <rev1> <rev2>` instead
- **`git reset`** — Use `jj abandon` or `jj new` instead
- **`git cherry-pick`** — Use `jj duplicate` instead
- **`git push`** — Use `jj git push` instead
- **`git tag`** — Use `jj tag` instead
- **`git stash`** — Use `jj squash` or `jj new` instead

### Generally Unnecessary for AIs

- **`--ignore-working-copy`** — AIs should always work with real working copy state
- **`--ignore-immutable`** — Bypasses safety; AIs should respect immutability
- **`--at-operation`** — Historical inspection is rarely needed
- **`jj config *`** — Config modification; AIs should not modify settings
- **`jj operation *`** — Low-level operation management
- **`jj util *`** — GC, manpage install, shell completions

---

## Global Options (Safe for AIs)

```bash
-R, --repository <path>   # Repository location
--quiet                   # Less output
--no-pager                # No interactive pager
```

Note: `--git` flag is **required** on `jj diff`, `jj show`, `jj log`, and `jj interdiff` for AI-parseable output. Without `--git`, these commands emit a compact custom format that AIs cannot reliably parse. This is **not a bug** — it is the default human-readable format. Always append `--git` when asking an AI to analyze diffs.

## Global Options (Avoid)

```bash
--ignore-working-copy     # DON'T use — work with real state
--ignore-immutable        # DON'T use — respect immutability
--at-operation            # DON'T use — rarely needed
--debug                   # DON'T use — debugging only
```

---

## Key Differences from Git — Quick Reference

| Aspect | Git | jj |
|--------|-----|----|
| Staging area | Yes (index) | No — working copy IS the commit |
| Creating commit | `git commit` moves HEAD | `jj commit` creates ON TOP of @, @ becomes empty |
| Branching | `git checkout -b` moves HEAD | `jj bookmark create` creates pointer, @ stays |
| Merging | `git merge` moves branch pointer | `jj new A B` creates merge, @ moves to new empty |
| Undo | Complex (`reflog`, `reset`) | `jj undo` — simple and reliable |
| Amending | `git commit --amend` changes content+msg | `jj describe` changes msg only; `jj squash` changes content |
| Commit identity | SHA-1 hash | Separate change_id (stable) + commit_id (can change on rewrite) |
| Interactive staging | `git add -p` | `jj commit -i` or `jj-hunk` |
| Selective file commit | Not built-in | `jj-hunk commit '<spec>' "msg"` |
| Split into logical commits | `git add -p` + multiple commits | `jj-hunk split '<spec>' "msg"` |

---

## Getting Help

### Built-in Help
Every jj and jj-hunk command has a `--help` flag. Use it when you need details on a specific command:

```bash
jj --no-pager <command> --help          # e.g., jj rebase --help
jj-hunk <command> --help                # e.g., jj-hunk split --help
```

### Official Documentation
Full docs: [github.com/jj-vcs/jj/tree/main/docs](https://github.com/jj-vcs/jj/tree/main/docs)

### If Help Is Insufficient
If this skill doesn't cover a scenario and you need to consult external docs or experiment to figure something out, **notify the user** and log a todo to improve the skill:

```
⚠️ This required consulting external docs. Consider adding this to the skill: <topic>.
```

The goal is to make this skill self-contained enough that an AI can handle any jj task without falling back to the user for tool selection. If a gap is found, flag it so the skill can be updated.