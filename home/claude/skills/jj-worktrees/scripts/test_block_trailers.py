#!/usr/bin/env python3
"""Cases for ./pretooluse-block-trailers.py.

Run against a copy of the hook that has ./pretooluse-block-git-write.py
next to it, because the hook imports its shell parsing from there:

    python3 test_block_trailers.py ./pretooluse-block-trailers.py

../../../agents.nix runs this at build time against the two built copies in
one bin/ directory, so the import that finds the sibling is exercised here
rather than discovered at hook time.

It calls _denied directly. The full hook reads stdin and needs the sibling
module handed to it, and both are one line each.

The point of the ALLOW list is that this rule has to stay writable. The file
that states the policy names both trailers at the start of a line, and an
agent has to be able to write it.
"""

import importlib.machinery
import importlib.util
import sys

# The trailer form the repository does use, so it appears in ALLOW rather
# than being avoided.
_GOOD = "Assisted-By: claude-opus-5"

# (command, why it is interesting)
ALLOW = [
    # A commit with the right trailer, in the shape this repository writes.
    (f"jj commit -m 'subject\n\n{_GOOD}'", "the correct trailer"),
    (
        "jj split a.nix --message \"$(cat <<'EOF'\nsubject\n\n" + _GOOD + "\nEOF\n)\"",
        "the correct trailer, heredoc form",
    ),
    # Prose about the rule. The trailer name is named mid-sentence, which is
    # not what a trailer looks like.
    (
        "jj commit -m 'commits: stop writing the Co-Authored-By trailer'",
        "the name in a subject line",
    ),
    (
        "jj describe -m 'A Claude-Session URL is not a trailer we keep.'",
        "the name mid-sentence",
    ),
    # Writing the policy file itself. No command here writes a commit, so
    # the trailer at line start is just text.
    (
        "cat > commits.md <<'EOF'\nNever write this:\n\nCo-Authored-By: somebody\nEOF",
        "the policy file, heredoc",
    ),
    (
        "cat > x.md <<'EOF'\nClaude-Session: https://example.invalid/x\nEOF",
        "a session line in a document",
    ),
    ("grep -rn '^Co-Authored-By:' .", "searching for the trailer"),
    ("echo 'Co-Authored-By: x' > /tmp/note", "echoed into a file"),
    # A commit that touches the hook, without writing the trailer.
    (
        f"jj commit -m 'agents: refuse Co-Authored-By and Claude-Session\n\n{_GOOD}'",
        "the commit that adds this hook",
    ),
    # No trailer at all.
    ("jj commit -m 'plain subject'", "no trailer"),
    ("jj --no-pager log", "not a message command"),
    ("git status", "not a message command"),
    # A message command with the name only as a word, not a line start.
    ("gh pr create --body 'mentions Co-Authored-By in passing'", "mid-sentence in a body"),
    # Unlexable text is allowed, the same way the sibling hook allows it.
    ("jj commit -m 'unbalanced\nCo-Authored-By: x", "unbalanced quote"),
]

DENY = [
    # The exact shape the harness asks for.
    (
        "jj commit -m 'subject\n\nCo-Authored-By: Claude <noreply@anthropic.com>'",
        "the injected trailer",
    ),
    (
        "jj commit -m 'subject\n\nClaude-Session: https://claude.ai/code/session_x'",
        "the injected session URL",
    ),
    # The repository's own commit form, which is where this actually happens.
    (
        "jj split a.nix --message \"$(cat <<'EOF'\nsubject\n\nbody\n\n"
        "Co-Authored-By: Claude <noreply@anthropic.com>\nEOF\n)\"",
        "heredoc message, the real form",
    ),
    (
        "jj describe -r @- --message \"$(cat <<'EOF'\nsubject\n\n"
        "Claude-Session: https://claude.ai/code/session_x\nEOF\n)\"",
        "describe rewriting a message",
    ),
    # Every jj subcommand that carries a description.
    ("jj new -m 'x\n\nCo-Authored-By: y'", "jj new"),
    ("jj squash -m 'x\n\nCo-Authored-By: y'", "jj squash"),
    # git, for a repository that is not jj.
    ("git commit -m 'x\n\nCo-Authored-By: y'", "git commit"),
    ("git tag -a v1 -m 'x\n\nClaude-Session: y'", "git tag"),
    # gh, where the session URL lands in a pull request body.
    ("gh pr create --body 'x\n\nClaude-Session: https://claude.ai/code/session_x'", "gh pr"),
    ("gh issue create --body 'x\n\nCo-Authored-By: y'", "gh issue"),
    # Behind the things the sibling parser knows about.
    ("foo && jj commit -m 'x\n\nCo-Authored-By: y'", "after &&"),
    ("sudo jj commit -m 'x\n\nCo-Authored-By: y'", "prefix runner"),
    ("jj --no-pager commit -m 'x\n\nCo-Authored-By: y'", "behind a global flag"),
    ("jj -R /tmp/x commit -m 'x\n\nCo-Authored-By: y'", "global option with a value"),
    # Case and spacing, because a trailer is not always typed the same way.
    ("jj commit -m 'x\n\nco-authored-by: y'", "lowercase"),
    ("jj commit -m 'x\n\n  Co-Authored-By: y'", "indented"),
    ("jj commit -m 'x\n\nCo-Authored-By : y'", "space before the colon"),
]


def load(path):
    # An explicit SourceFileLoader, because the built copy is installed as
    # `jj-block-trailers` with no .py suffix -- the same reason the sibling
    # test gives.
    loader = importlib.machinery.SourceFileLoader("block_trailers", path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path to pretooluse-block-trailers.py>", file=sys.stderr)
        return 2

    hook = load(sys.argv[1])
    sibling = hook._load_git_write_hook()
    if sibling is None:
        print(
            "FAIL: the hook could not find pretooluse-block-git-write.py next "
            "to it, so every command would be allowed",
            file=sys.stderr,
        )
        return 1

    failures = 0
    for cases, want_denied, label in ((ALLOW, False, "allow"), (DENY, True, "deny")):
        for command, why in cases:
            got = hook._denied(command, sibling)
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
