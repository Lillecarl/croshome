#!/usr/bin/env python3
"""Cases for ./pretooluse-block-git-write.py.

Run against a copy of the hook:

    python3 test_block_git_write.py ./pretooluse-block-git-write.py

../../../agents.nix runs this at build time, so a parsing regression is a
failed build rather than a hook that quietly refuses legitimate commands.

It calls _denied_git_command directly rather than driving the script over
stdin, because the full hook also asks `jj root` whether the working
directory is a jj repo -- and there is no jj, and no repo, inside a build
sandbox. That check is covered by ./test-cases in prose rather than here:
its two answers are "not a jj repo" and "no jj at all", both of which mean
allow, and both of which are one line of _is_jj_repo.

Cases mention git freely, in command position and out of it. That is the
point: the hook this tests is the reason such text is safe to write.
"""

import importlib.machinery
import importlib.util
import sys

# (command, why it is interesting)
ALLOW = [
    # The false positives that prompted the rewrite. Each of these was
    # refused by the previous text-scanning version.
    ("jj commit -m 'never use git directly, use jj'", "prose in a commit message"),
    ("cat > f <<'EOF'\nthe git subcommand is blocked\nEOF", "heredoc body"),
    ("cat > f <<'EOF'\ngit push\nEOF", "heredoc body, imperative"),
    ("cat > f <<'EOF'\nrun this; git push\nEOF", "heredoc body with a separator"),
    ("cat > f <<-EOF\ngit push\n\tEOF", "indented heredoc"),
    ("grep -rn 'git commit' AGENTS.md", "search pattern"),
    ("echo 'do not run git reset'", "echoed prose"),
    ('jj describe -m "documents git push and git commit"', "prose, double quoted"),
    # A file or argument that happens to be called git.
    ("cat > git", "redirection target named git"),
    ("ls git", "argument named git"),
    ("echo git", "bare word, not a command"),
    # A redirection before the subcommand. This is the case that makes
    # skipping redirection targets earn its keep: read as arguments, ">"
    # is the first thing that does not look like an option and gets taken
    # for the subcommand, so a plain `status` reads as a write.
    ("git > out status", "redirection between git and its subcommand"),
    # Read-only subcommands are on the allowlist.
    ("git status", "read-only"),
    ("git log --oneline", "read-only"),
    ("git diff HEAD", "read-only"),
    ("git -C /tmp/x status", "read-only behind a global option with a value"),
    # jj is jj's business, whatever it is doing.
    ("jj git push", "jj interop"),
    ("jj --no-pager git fetch", "jj interop behind a global flag"),
    ("jj -R /tmp/x git push", "jj interop behind a global option with a value"),
    ("jj --at-op @- git push", "jj interop"),
    ("jj --config=ui.color=never git push", "jj interop, inline option value"),
    ("jj --no-pager log", "plain jj"),
    ("jj --no-pager git push && jj --no-pager git fetch", "two jj interop calls"),
    # Unlexable text is allowed rather than guessed at: a false positive
    # costs more than a false negative here.
    ("echo 'unbalanced", "unbalanced quote"),
]

DENY = [
    ("git push", "bare write"),
    ("git commit -m x", "bare write"),
    ("git reset --hard origin/main", "bare write"),
    ("git rebase main", "bare write"),
    ("git stash list", "dual-mode, deliberately not allowlisted"),
    ("/usr/bin/git push", "invoked by full path"),
    ("foo && git push", "after &&"),
    ("foo; git merge x", "after ;"),
    ("foo || git commit -m x", "after ||"),
    ("echo x | git apply", "after a pipe"),
    ("jj git push && git push", "second call is real git"),
    ("sh -c 'git push'", "nested sh -c"),
    ('bash -c "git reset --hard"', "nested bash -c"),
    ("echo $(git push)", "command substitution"),
    ("echo `git push`", "backtick substitution"),
    ("sudo git push", "prefix runner"),
    ("env FOO=1 git push", "env with an assignment"),
    ("timeout 5 git push", "prefix runner with an argument"),
    ("git -C /tmp push", "global option with a value"),
    ("git --git-dir=/tmp/x push", "inline global option"),
]


def load(path):
    # An explicit SourceFileLoader, because the built copy is installed as
    # `jj-block-git-write` with no .py suffix and spec_from_file_location
    # infers the loader from the extension -- it returns a spec with no
    # loader at all rather than failing outright.
    loader = importlib.machinery.SourceFileLoader("block_git_write", path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path to pretooluse-block-git-write.py>", file=sys.stderr)
        return 2

    decide = load(sys.argv[1])._denied_git_command
    failures = 0

    for cases, want_denied, label in ((ALLOW, False, "allow"), (DENY, True, "deny")):
        for command, why in cases:
            got = decide(command)
            if bool(got) != want_denied:
                failures += 1
                shown = command.replace("\n", "\\n")
                print(
                    f"FAIL: expected {label} but got "
                    f"{'deny (' + got + ')' if got else 'allow'}: {shown}  [{why}]",
                    file=sys.stderr,
                )

    total = len(ALLOW) + len(DENY)
    if failures:
        print(f"{failures} of {total} cases failed", file=sys.stderr)
        return 1
    print(f"all {total} cases pass ({len(ALLOW)} allow, {len(DENY)} deny)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
