---
name: jj
description: Jujutsu VCS (version control system) skill. Use for all jj/jujutsu operations including repository management, commit manipulation, history traversal, branching with bookmarks, and Git interoperability.
---

# jj (Jujutsu) Skill

Jujutsu is an experimental version control system that combines the best aspects of Git (speed, compatibility) with improved usability (no "detached HEAD" state, intuitive undo, better conflict handling).

## Quick Reference

### Global Options
- `-R <path>` — Repository path (default: auto-search for `.jj/`)
- `--ignore-working-copy` — Don't snapshot/update working copy
- `--ignore-immutable` — Allow rewriting immutable commits
- `--at-operation <id>` — Load repo at specific operation ID
- `--quiet` — Silence non-primary output
- `--no-pager` — Disable pager

### Common Aliases
- `jj st` = `jj status`
- `jj log` = `jj log`
- `jj ci` = `jj commit`
- `jj desc` = `jj describe`
- `jj b` = `jj bookmark`
- `jj n` = `jj new`

---

## Revset Language (Critical for AI Understanding)

**Revsets** are expressions that select a set of commits. Most `jj` commands accept a revset.

### Symbols
| Symbol | Meaning |
|--------|---------|
| `@` | Working copy commit |
| `<name>@` | Working copy in another workspace |
| `<name>@<remote>` | Remote-tracking bookmark/tag |
| `<commit-id>` | Full or prefix commit ID |
| `<change-id>` | Full or prefix change ID |

### Operators (binding order, strongest first)
1. `f(x)` — Function call
2. `x-` — Parents of x (empty if root)
   `x+` — Children of x (empty if no children)
3. `p:x` — Pattern alias
4. `x::` — Descendants of x (including x)
   `x..` — Not ancestors of x
   `::x` — Ancestors of x (including x)
   `..x` — Ancestors of x, excluding root
   `x::y` — Descendants of x that are ancestors of y
   `x..y` — Ancestors of y not ancestors of x
   `::` — All visible commits
   `..` — All visible commits except root
5. `~x` — Not in x
6. `x & y` — In both x and y
   `x ~ y` — In x but not y
7. `x | y` — In either x or y

### Important Functions
- `parents(x)` / `x-` — Parents
- `children(x)` / `x+` — Children
- `ancestors(x)` / `::x` — Ancestors
- `descendants(x)` / `x::` — Descendants
- `all()` — All visible commits
- `none()` — No commits
- `bookmarks([pattern])` — Local bookmarks
- `remote_bookmarks([name], [remote])` — Remote bookmarks
- `tags([pattern])` — Tags
- `visible_heads()` — Visible heads
- `root()` — Virtual root commit
- `heads(x)` — Heads of x
- `latest(x, [count])` — Latest commits by timestamp
- `mine()` — Commits by current user
- `empty()` — Commits modifying no files
- `conflicts()` — Commits with conflicts
- `divergent()` — Divergent changes
- `present(x)` — x, or none() if missing
- `coalesce(revsets...)` — First non-none revset
- `trunk()` — Default remote bookmark head
- `mutable()` — Mutable commits
- `immutable()` — Immutable commits

### String Patterns
- `exact:"string"` — Exact match
- `glob:"pattern"` — Shell wildcards
- `regex:"pattern"` — Regular expression
- `substring:"string"` — Contains substring
- Append `-i` for case-insensitive

### Date Patterns
- `after:"date"` — On or after date
- `before:"date"` — Before date
- Formats: `2024-02-01`, `2 days ago`, `yesterday 5pm`

### Built-in Aliases
- `trunk()` — Head of default remote bookmark
- `immutable()` — Commits treated as immutable
- `mutable()` — Commits treated as mutable

### Examples
```bash
jj log -r @-           # Parent of working copy
jj log -r ::@          # Ancestors of working copy
jj log -r 'remote_bookmarks()..'  # Local-only commits
jj log -r 'author(*martinvonz*) & description(*reset*)'
jj log -r 'main..@'    # Commits since main
```

---

## Core Commands

### jj — Main entry point
Global options apply to all subcommands.

### jj-help — Display help
- `jj help` — List all commands
- `jj help -k revsets` — Show help by keyword
- Keywords: `bookmarks`, `config`, `filesets`, `glossary`, `revsets`, `templates`, `tutorial`

### jj-version — Show version

### jj-root — Show workspace root

### jj-status — Repository status
Shows: working copy commit, parents, changes summary, conflicts, conflicted bookmarks.

### jj-log — Revision history
```bash
jj log                    # Show history
jj log -r ::             # Show all commits (including immutable)
jj log -n 10 --reversed  # Oldest first
jj log -p                 # Show patches
jj log --stat             # Show diff stats
```
**Symbols in graph:** `@` = working copy, `◆` = immutable, `○` = normal

### jj-show — Show commit details
```bash
jj show                  # Show @ by default
jj show -r <revset>      # Show specific revision
```

### jj-diff — Compare revisions
```bash
jj diff                  # Diff @ vs parent
jj diff -r @             # Same as above
jj diff -f A -t B        # Diff A to B
```

---

## Commit Editing

### jj-new — Create new commit
```bash
jj new                   # Create empty commit after @
jj new -m "message"      # With message
jj new -A <rev>          # Insert after rev
jj new -B <rev>          # Insert before rev
jj new @ main            # Merge commit (multiple parents)
```

### jj-commit — Commit working copy
```bash
jj commit                # Describe + new (acts on @)
jj commit -i             # Interactive selection
jj commit -m "message"   # Direct message
```

### jj-describe — Update description
```bash
jj describe              # Open editor
jj describe -m "msg"    # Direct message
jj describe -r <rev>     # Describe rev
```

### jj-edit — Set working copy
```bash
jj edit <revset>         # Switch to revision
```
**Note:** `jj new` + `jj squash` is usually preferred.

### jj-split — Split into two commits
```bash
jj split                 # Interactive diff editor
jj split -r <rev>        # Split specific revision
jj split -p              # Parallel siblings
```

### jj-squash — Combine commits
```bash
jj squash                # Squash @ into parent
jj squash -f <from> -t <into>  # Squash from->into
jj squash -i             # Interactive
```

### jj-rebase — Move commits
```bash
jj rebase -s <rev> -o <onto>    # Rebase rev onto target
jj rebase -b <bookmark>         # Rebase entire branch
jj rebase -r <rev>              # Rebase only rev
jj rebase -s L -o K -o M        # Create merge commit
```

---

## History Navigation

### jj-prev — Move to parent
```bash
jj prev                 # Go to parent (creates new @)
jj prev -e              # Edit parent directly
jj prev --conflict      # Jump to previous conflicted
```

### jj-next — Move to child
```bash
jj next                 # Go to child
jj next -e              # Edit child directly
```

### jj-undo — Undo last operation
```bash
jj undo                 # Step backward in op history
jj redo                 # Step forward
```

### jj-evolog — Show change evolution
```bash
jj evolog -r <rev>      # Follow how rev evolved
```

### jj-bisect — Binary search for bad commit
```bash
jj bisect run --range v1.0..main -- bash -c "cargo test"
```

---

## File Operations

### jj-file-list — List files
```bash
jj file list -r <rev>   # List files in revision
```

### jj-file-show — Show file contents
```bash
jj file show -r <rev> <path>
```

### jj-file-search — Search file content
```bash
jj file search -r <rev> -p '*.rs' <pattern>
```

### jj-file-annotate — Blame
```bash
jj file annotate <path>
```

### jj-file-chmod — Set executable bit
```bash
jj file chmod +x <path>  # Add executable
jj file chmod n <path>   # Remove executable
```

### jj-file-track — Start tracking
### jj-file-untrack — Stop tracking
```bash
jj file untrack <path>   # Must be ignored first
```

---

## Bookmarks (Branches)

### jj-bookmark — Parent command

### jj-bookmark-list — List bookmarks
```bash
jj bookmark list
jj bookmark list -a      # All remotes
jj bookmark list -t      # Tracked only
```

### jj-bookmark-create — Create bookmark
```bash
jj bookmark create <name> -r <rev>
```

### jj-bookmark-set — Create or update
```bash
jj bookmark set <name>    # Points to @
```

### jj-bookmark-move — Move bookmark
```bash
jj bookmark move -f <old> -t <new>
```

### jj-bookmark-rename — Rename
```bash
jj bookmark rename <old> <new>
```

### jj-bookmark-delete — Delete (propagates)
### jj-bookmark-forget — Delete (local only)
```bash
jj bookmark forget <name>  # Doesn't propagate to remote
```

### jj-bookmark-advance — Advance to target
### jj-bookmark-track — Track remote bookmark
### jj-bookmark-untrack — Stop tracking

---

## Tags

### jj-tag-list — List tags
### jj-tag-set — Create/update tag
```bash
jj tag set v1.0 -r <rev>
```

### jj-tag-delete — Delete tag

---

## Git Interoperability

### jj-git-clone — Clone Git repo
```bash
jj git clone <url> [dest]
jj git clone --colocate    # Default: colocated
```

### jj-git-fetch — Fetch from remote
### jj-git-push — Push to remote
```bash
jj git push
jj git push -r <revset>   # Push specific revisions
jj git push --deleted      # Push deletions
```

### jj-git-export — Export to Git (usually auto)
### jj-git-import — Import from Git (usually auto)

### jj-git-remote — Manage remotes
```bash
jj git remote add <name> <url>
jj git remote list
```

### jj-git-colocation — Colocation management
```bash
jj git colocation status
jj git colocation enable
jj git colocation disable
```

---

## Workspaces

### jj-workspace — Parent command

### jj-workspace-add — Add workspace
```bash
jj workspace add <path> -r <rev>
```

### jj-workspace-list — List workspaces
### jj-workspace-forget — Remove workspace
### jj-workspace-root — Show workspace root

### jj-workspace-update-stale — Update stale workspace

---

## Operations (Advanced)

### jj-operation-log — View operation history
```bash
jj op log
jj op log -n 10
```

### jj-operation-restore — Restore to operation
```bash
jj op restore <operation-id>
```

### jj-operation-abandon — Abandon operation history

---

## Configuration

### jj-config-list — List config
```bash
jj config list
jj config list --include-defaults
```

### jj-config-get — Get value
```bash
jj config get user.name
```

### jj-config-set — Set value
```bash
jj config set user.name "Name" --user
```

### jj-config-edit — Edit config file
```bash
jj config edit --user
```

### jj-config-path — Show config paths

---

## Advanced Commands

### jj-absorb — Move changes into stack
```bash
jj absorb                   # Move @ changes to closest mutable ancestors
jj absorb -f <rev>         # From specific revision
```

### jj-duplicate — Duplicate commits
```bash
jj duplicate -o <onto>      # Duplicate onto different parent
```

### jj-fix — Run formatters/linters
```bash
jj fix                     # Fix code in mutable commits
jj fix --include-unchanged  # Even unchanged files
```

### jj-resolve — Resolve merge conflicts
```bash
jj resolve                  # Resolve with merge tool
jj resolve --list           # List conflicts
jj resolve --tool :ours     # Use ours/theirs
```

### jj-restore — Restore files
```bash
jj restore <path>           # Undo changes in working copy
jj restore -f <rev> <path>  # Restore from revision
```

### jj-revert — Apply reverse changes
```bash
jj revert -r <rev>          # Create inverse of rev
```

### jj-sparse — Sparse checkout
```bash
jj sparse list              # Show patterns
jj sparse set --add <pattern>
jj sparse reset             # Show all files
```

### jj-split — Split commit
See Commit Editing.

### jj-squash — Squash commits
See Commit Editing.

### jj-parallelize — Make commits siblings
```bash
jj parallelize <revset>     # Declare independence
```

### jj-sign / jj-unsign — Cryptographic signing
### jj-simplify-parents — Remove redundant parents

### jj-interdiff — Compare diffs
```bash
jj interdiff -f A -t B
```

### jj-arrange — Interactive graph editing

### jj-metaedit — Modify commit metadata
```bash
jj metaedit -m "new message" -r <rev>
jj metaedit --update-author -r <rev>
```

### jj-abandon — Abandon revision
```bash
jj abandon <revset>
```

### jj-util — Utility commands
```bash
jj util completion bash     # Shell completions
jj util config-schema       # JSON schema for config
jj util gc                 # Garbage collection
```

### jj-gerrit — Gerrit integration
```bash
jj gerrit upload -r <rev> --remote <ssh-url>
```

---

## Common Workflows

### Daily Development
```bash
jj status          # Check what's changed
jj log -n 5        # Review recent commits
jj new -m "feat: add feature"  # Create commit
jj git push        # Push to remote
```

### Undo Mistakes
```bash
jj undo           # Undo last operation
jj op log         # Find earlier state
jj op restore <id>  # Restore to operation
```

### Rebase Work
```bash
jj rebase -s @ -o main    # Rebase onto main
jj rebase -b feature       # Rebase entire branch
```

### View History
```bash
jj log                     # Graph view
jj log -r '::@ & empty()' # Show empty commits
jj show <rev>              # Full commit details
```

### Manage Conflicts
```bash
jj resolve                  # Open merge tool
jj log --stat -r conflicts()  # Find conflicts
```

### Work with Multiple Workspaces
```bash
jj workspace add ../other -r @
jj workspace list
```
