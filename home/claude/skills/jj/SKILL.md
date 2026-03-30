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

---

## Git to jj Command Mapping

| Git Command | jj Command | Key Difference |
|-------------|------------|----------------|
| `git status` | `jj status` (alias: `jj st`) | Shows @ commit with its changes inline |
| `git log` | `jj log` | Graph view; use `-r ::` to see immutable commits |
| `git show` | `jj show` | Shows description + diff for a commit |
| `git diff` | `jj diff` | Defaults to `jj diff -r @` (working copy vs parent) |
| `git add` | `jj file track` | Auto-tracks new files; no staging needed |
| `git add -p` | `jj commit -i` | Interactive staging for partial commits |
| `git checkout -- <path>` | `jj restore <path>` | Restore file from parent/other revision |
| `git commit` | `jj commit` (alias: `jj ci`) | Creates commit ON TOP of @ — does NOT move bookmarks |
| `git commit --amend` | `jj describe` (alias: `jj desc`) | Updates message; does NOT change content like Git amend |
| `git reset <rev>` | `jj new <rev>` | jj new places you ON the commit (creates working-copy there) |
| `git checkout -b <name>` | `jj bookmark create <name>` | Creates bookmark pointing to @ |
| `git branch -d <name>` | `jj bookmark forget <name>` | Local-only deletion; use `jj bookmark delete` to propagate |
| `git rebase` | `jj rebase` | More powerful: `-s` (source+descendants), `-b` (branch), `-r` (revisions only) |
| `git merge` | `jj new <rev1> <rev2>` | Create merge by specifying multiple parents |
| `git stash` | `jj squash @` | Squashes @ into parent as working-copy; or `jj squash -r @` |
| `git cherry-pick` | `jj duplicate` | Copies commit content to new location |
| `git revert` | `jj revert` | Creates new commit with inverse changes |
| `git push` | `jj git push` | Force-with-lease by default; remote derived from bookmarks |
| `git fetch` | `jj git fetch` | |
| `git clone` | `jj git clone` | |
| `git reflog` | `jj undo` / `jj op log` | `jj undo` = step backward; `jj op log` = full history |
| `git checkout <rev>` | `jj edit <rev>` | Sets revision as working-copy commit |
| `git merge --abort` | `jj op restore @-` | Restore to previous operation |
| `git mergetool` | `jj resolve` | 3-way merge tool support |
| `git tag` | `jj tag` | Similar subcommands (list, set, delete) |
| `git clean -fd` | `jj file untrack` + rm | Untrack then delete |
| `git worktree add` | `jj workspace add` | Multiple working copies on same repo |

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

---

## Best Practices for AI Agents

### Use `jj commit` to Finish a Task
AIs should prefer `jj commit -m "message"` over `jj describe`. 
- `jj commit` creates a new revision ON TOP of the current one and moves the `@` (working copy) to a new empty commit. This prevents "task bleed" where new changes accidentally accumulate in the same revision.
- `jj describe` only labels the current revision. If used, the AI must remember to call `jj new` manually before starting the next task.

### Always Use `--no-pager`
AIs MUST always include `--no-pager` for every `jj` command to ensure non-interactive execution and prevent the process from hanging or being truncated by a pager.

```bash
jj --no-pager <command>
```

---

## Critical Revset Language

**Revsets** select commits. Most jj commands accept a revset.

### Symbols
| Symbol | Meaning |
|--------|---------|
| `@` | Working copy commit |
| `<name>@` | Working copy in another workspace |
| `<name>@<remote>` | Remote-tracking bookmark |
| `<commit-id>` | Full or prefix commit ID |
| `<change-id>` | Full or prefix change ID |

### Operators (binding strength, strongest first)
```
f(x)         — function call
x-           — parents of x
x+           — children of x
x::          — descendants of x (including x)
x..          — NOT ancestors of x
::x          — ancestors of x (including x)
..x          — ancestors of x, excluding root
x::y         — descendants of x that are ancestors of y
x..y         — ancestors of y that are not ancestors of x
~x           — not in x
x & y        — in both x and y
x ~ y        — in x but not y
x | y        — in either x or y
```

### Key Functions
| Function | Meaning |
|----------|---------|
| `parents(x)`, `x-` | Parents |
| `children(x)`, `x+` | Children |
| `ancestors(x)`, `::x` | Ancestors |
| `descendants(x)`, `x::` | Descendants |
| `bookmarks()` | Local bookmarks |
| `remote_bookmarks(r)` | Remote bookmarks, optionally filtered by remote |
| `tags()` | Tags |
| `all()` | All visible commits |
| `none()` | No commits |
| `visible_heads()` | Heads of visible commits |
| `root()` | Virtual root commit |
| `heads(x)` | Heads of x |
| `latest(x,n)` | Latest n commits by timestamp |
| `mine()` | Current user's commits |
| `empty()` | Commits modifying no files |
| `conflicts()` | Commits with conflicts |
| `trunk()` | Default remote bookmark head |
| `mutable()` | Mutable commits |
| `immutable()` | Immutable commits |

### String Patterns
- `exact:"string"` — exact match
- `glob:"*.rs"` — shell wildcards
- `regex:"pattern"` — regular expression
- `substring:"text"` — contains substring
- Append `-i` for case-insensitive

### Date Patterns
- `after:"2024-01-01"` — on or after date
- `before:"2 days ago"` — before date

### Revset Examples
```bash
jj log -r @-                 # Parent of working copy
jj log -r ::@                # Ancestors of working copy
jj log -r 'main..@'          # Local commits since main
jj log -r 'remote_bookmarks()..'  # Not on any remote
jj log -r 'author(*name*) & description(*fix*)'  # Combined
jj diff -r 'B::D'            # Diff range B through D
```

---

## Common Commands

### Navigation
```bash
jj --no-pager status              # Repo status (shows @ commit)
jj --no-pager log                 # Revision history
jj --no-pager log -n 20           # Last 20 commits
jj --no-pager log --reversed       # Oldest first
jj --no-pager show                # Show @ commit
jj --no-pager show -r <rev>       # Show specific revision
```

### Viewing Diffs

**IMPORTANT:** jj defaults to a compact inline diff format that humans find intuitive but AIs do not understand. Only these commands support `--git` for Git-format diffs:

- `jj diff --git`
- `jj show --git`
- `jj log --git -p`
- `jj evolog --git -p`
- `jj interdiff --git -f A -t B`
- `jj operation diff --git`
- `jj operation log --git`
- `jj operation show --git`

```bash
jj --no-pager diff --git                 # Diff @ in Git format
jj --no-pager diff --git -r <rev>        # Diff specific revision
jj --no-pager diff --git -r A::B         # Diff range A through B
jj --no-pager show --git                 # Show @ diff in Git format
jj --no-pager show --git -r <rev>        # Show revision diff in Git format
jj --no-pager log --git -p -r <rev>      # Patch in Git format
jj --no-pager interdiff --git -f A -t B  # Compare diffs in Git format
```

Without `--git`, jj produces inline diffs with color annotations that are not parseable by AIs.

### Creating & Editing Commits
```bash
jj --no-pager new                      # Create empty commit after @
jj --no-pager new -m "message"         # With message
jj --no-pager new -A <rev>             # Insert after rev
jj --no-pager new @ main               # Create merge commit

jj --no-pager commit                   # Commit working copy (@)
jj --no-pager commit -i                # Interactive partial commit
jj --no-pager commit -m "message"      # Direct message

jj --no-pager describe                 # Edit commit message (opens editor)
jj --no-pager describe -m "message"    # Direct message

jj --no-pager split                    # Split @ into two commits
jj --no-pager split -r <rev>          # Split specific revision
jj --no-pager split -p                # Parallel siblings

jj --no-pager squash                   # Squash @ into parent
jj --no-pager squash -f <from> -t <into>  # Squash from->into
```

### Moving Commits
```bash
jj --no-pager rebase -s @ -o main      # Rebase @ onto main
jj --no-pager rebase -b <bookmark>     # Rebase entire branch
jj --no-pager rebase -s L -o K -o M     # Create merge commit (multiple -o)
jj --no-pager rebase -r <rev>          # Rebase only (no descendants)
```

### Navigation Between Commits
```bash
jj --no-pager prev                 # Go to parent (creates new @)
jj --no-pager next                 # Go to child
jj --no-pager edit <rev>           # Set @ to revision
```

### File Operations
```bash
jj --no-pager file list            # List files in @
jj --no-pager file show -r <rev> <path>  # Show file content
jj --no-pager file search -p '*.rs' <pattern>  # Search in files
jj --no-pager file annotate <path>   # Blame
jj --no-pager file chmod +x <path>   # Set executable
jj --no-pager restore <path>         # Restore file from parent
jj --no-pager restore -f <rev> <path>  # Restore from specific revision
```

### Undo
```bash
jj --no-pager undo                 # Undo last operation
jj --no-pager redo                 # Redo (after jj undo)
jj --no-pager op log               # Full operation history
jj --no-pager op restore <id>       # Restore to specific operation
```

### Resolving Conflicts
```bash
jj --no-pager resolve               # Open merge tool
jj --no-pager resolve --list        # List conflicts
jj --no-pager resolve --tool :ours  # Use ours/theirs
```

---

## Bookmarks (Branches)

```bash
jj --no-pager bookmark list              # List bookmarks
jj --no-pager bookmark list -a           # Include remotes
jj --no-pager bookmark create <name>     # Create bookmark on @
jj --no-pager bookmark set <name>        # Create or update
jj --no-pager bookmark move -f <old> -t <new>  # Move
jj --no-pager bookmark rename <old> <new>
jj --no-pager bookmark delete <name>     # Delete (propagates to remote)
jj --no-pager bookmark forget <name>     # Delete (local only)
```

---

## Remote Operations

```bash
jj --no-pager git clone <url> [dest]     # Clone Git repo
jj --no-pager git fetch                  # Fetch from remote
jj --no-pager git push                   # Push bookmarks
jj --no-pager git push -r <revset>       # Push specific revisions
jj --no-pager git push --deleted         # Push deletions
jj --no-pager git remote add <name> <url>
```

---

## Tags

```bash
jj --no-pager tag list
jj --no-pager tag set <name> -r <rev>
jj --no-pager tag delete <name>
```

---

## Advanced Commands

```bash
jj --no-pager absorb              # Move changes from @ into stack of mutable commits
jj --no-pager duplicate           # Duplicate commit to new location
jj --no-pager fix                 # Run formatters/linters
jj --no-pager parallelize         # Make commits siblings (declare independence)
jj --no-pager revert -r <rev>    # Apply reverse of rev
jj --no-pager interdiff -f A -t B # Compare diffs of two revisions
jj --no-pager arrange             # Interactive graph arrangement
jj --no-pager metaedit -m "msg"  # Change commit message
```

---

## What AIs Should NOT Use

These exist but are not needed by AIs:

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

Note: `--git` flag is only available on diff/show/log commands, not a global option.

## Global Options (Avoid)

```bash
--ignore-working-copy     # DON'T use — work with real state
--ignore-immutable        # DON'T use — respect immutability
--at-operation           # DON'T use — rarely needed
--debug                   # DON'T use — debugging only
```
