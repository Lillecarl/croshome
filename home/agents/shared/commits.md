## Commits

Write the subject and the body. End every commit you make with exactly one
trailer, on the last line after a blank line:

    Assisted-By: <your model name>

For example `Assisted-By: ox-alpha`. Every commit an agent makes is made
autonomously, so every commit you make carries it.

One exception holds. Contributions to nixpkgs, to Nix itself, and to other
upstream Nix projects require `Co-Authored-By:` as the disclosure of AI work;
there that trailer replaces this one.

No other trailer of any kind, anywhere. A commit carries either `Assisted-By`
or, upstream, `Co-Authored-By`, and never both, never more.

## Commit as you go

Commit each finished piece before you start the next one. Do not implement ten
things and then write one commit for all of them. A commit is a unit of work I
can read, revert or cherry-pick on its own. That stops working when it holds
five unrelated changes.

The test is simple. If the subject line needs the word "and", the work is two
commits.

Commit when a piece works, even if the whole task is not done. A half-finished
task with four clean commits is better than a finished task with one big one.

## When the working copy already mixes concerns

You do not have to plan the split in advance. `jj split` separates a messy
working copy after the fact, and it is non-interactive when you name the files:

```sh
jj --no-pager split path/to/file.py --message "$(cat <<'EOF'
the message for that part
EOF
)"
```

The named files go into the first commit. The rest stays in `@`. Repeat until
each concern has its own commit.

Use `jj-hunk` when one file holds two concerns in the same diff, because
`jj split` only works per file.

The `jj` skill holds the details. Read `references/splitting.md` before your
first split, and `references/jj-hunk.md` for the hunk-level case. Never run
`jj split` with no file arguments: it opens an editor and hangs the session.
