#!/usr/bin/env python3
"""Cases for ./pretooluse-block-pgrep.py.

Run against a copy of the hook that has pretooluse-block-git-write.py next to
it, because the hook imports its shell parsing from there:

    python3 test_block_pgrep.py ./pretooluse-block-pgrep.py

../../../agents.nix runs this at build time against the built copies in one
bin/, so the import that finds the parser is exercised here rather than
discovered at hook time, and a regression is a failed build rather than a
refused command in a session.

The ALLOW list is the point. A guard on a word this common has to leave the
word writable: the policy file names it, so does a search for it, and so does
this test. A false refusal blocks ordinary work and is much harder to notice
than a miss.
"""

import importlib.machinery
import importlib.util
import sys

# (command, why it is interesting)
ALLOW = [
    ("grep -rn pgrep home/agents/", "searching for the word"),
    ("rg 'pgrep -f' --glob '*.md'", "searching for the whole form"),
    ("echo 'do not use pgrep here'", "the word in prose"),
    (
        "cat > tools.md <<'EOF'\nNever run this:\n\npgrep -f X\nEOF",
        "writing the policy file, heredoc body",
    ),
    (
        "cat > note.md <<EOF\npkill -f something\nEOF",
        "an unquoted heredoc body",
    ),
    ("pidof nginx", "the replacement for the exact-name case"),
    ("kill -0 $pid", "the replacement for a pid in hand"),
    ("pkill -x some-daemon", "pkill by exact name matches nothing of ours"),
    ("ps aux | head -20", "ps without a grep"),
    ("jj commit -m 'agents: ban pgrep from a tool-run shell'", "a commit about it"),
    ("ls /usr/bin | grep pgrep", "looking for the binary"),
    ("cat notes > pgrep.md", "a redirection target, not a command"),
    ("./configure --with-pgrep", "an option that happens to say it"),
    ("grep -n vfkit saved-ps.txt", "a grep with no ps of its own"),
]

DENY = [
    ("pgrep -f 'nix build'", "the plain case"),
    ("pgrep nginx", "every pgrep, per the policy"),
    ("until ! pgrep -f X; do sleep 5; done", "the loop that hangs"),
    ("while pgrep -f vfkit; do sleep 2; done", "the other loop that hangs"),
    ("pgrep -af qemu || true", "bundled flags, failure swallowed"),
    ("if pgrep -f foo >/dev/null; then echo yes; fi", "inside a condition"),
    ("echo start && pgrep -f foo", "after a separator"),
    ("out=$(pgrep -f foo)", "in a substitution"),
    ("sudo pgrep -f foo", "behind a prefix runner"),
    ("/run/current-system/sw/bin/pgrep -f foo", "by absolute path"),
    ("bash -c 'pgrep -f foo'", "inside a nested shell's argument"),
    ("pkill -f 'nix build'", "the self-killing form"),
    ("pkill --full vfkit", "the long spelling of it"),
    ("ps aux | grep vfkit", "the classic self-match"),
    ("ps -ef | grep -v grep | grep qemu", "even with the usual dodge"),
    ("ps aux > /tmp/p.txt; grep vfkit /tmp/p.txt", "through a file, same match"),
    ("while sudo pgrep -f x; do sleep 1; done", "a keyword and a runner"),
    ("timeout 5 pgrep -f foo", "a runner that takes a positional"),
    ("out=`pgrep -f foo`", "inside backticks"),
    ('sh -c "while pgrep -f x; do sleep 1; done"', "a keyword inside sh -c"),
]


def load(path):
    loader = importlib.machinery.SourceFileLoader("block_pgrep", path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path to pretooluse-block-pgrep.py>", file=sys.stderr)
        return 2

    hook = load(sys.argv[1])
    parser = hook._load_git_write_hook()
    if parser is None:
        print(
            "FAIL: the hook could not find pretooluse-block-git-write.py next "
            "to it, so every command would be allowed",
            file=sys.stderr,
        )
        return 1

    failures = 0
    for cases, want_denied, label in ((ALLOW, False, "allow"), (DENY, True, "deny")):
        for command, why in cases:
            got = hook._denied(command, parser)
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
