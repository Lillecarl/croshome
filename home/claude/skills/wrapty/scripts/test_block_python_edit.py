#!/usr/bin/env python3
"""Cases for ./pretooluse-block-python-edit.py.

Run against a copy with pretouse-block-git-write.py beside it, which is what
../../../agents.nix arranges:

    python3 test_block_python_edit.py ./pretooluse-block-python-edit.py

The ALLOW list is the important half. Python is how half of an investigation
gets done here, and a guard that catches `python3 -c 'json.load(...)'` or a
project's own script would cost far more than the habit it is aimed at.
"""

import importlib.machinery
import importlib.util
import sys

# The exact shape tools.md names, which is the reason this exists.
_THE_HABIT = (
    "python3 - <<'PY'\n"
    "src = open('wrapper.py').read()\n"
    "open('wrapper.py', 'w').write(src.replace('old', 'new'))\n"
    "PY"
)

# (command, why it is interesting)
ALLOW = [
    ("python3 build.py", "a program in the repository"),
    ("python3 ./scripts/render.py --out dist", "same, with arguments"),
    ("python3 -m pytest tests/ -x", "a module, not inline source"),
    ("python3 -m json.tool < in.json > out.json", "redirection is not inline source"),
    (
        "python3 -c 'import json,sys; print(json.load(sys.stdin)[\"a\"])'",
        "inline, but it only reads",
    ),
    ("python3 -c \"print(open('f').read())\"", "reading a file inline"),
    (
        "python3 -c 'import sys; sys.stdout.write(\"hello\")'",
        "writing to stdout is output, not an edit",
    ),
    (
        "cat > helper.py <<'PY'\nopen('f', 'w').write('x')\nPY",
        "writing a script file is not running one",
    ),
    (
        "echo \"never run python3 -c 'open(f,\\\"w\\\")'\"",
        "the habit named in prose",
    ),
    ("jj commit -m 'tools: stop editing files with python'", "a commit about it"),
    ("pyedit --apply edits.py", "the tool the refusal recommends"),
    ("grep -rn \"open(f, 'w')\" .", "searching for the pattern"),
    # The deliberate way out, in the spellings it has to survive.
    (
        "I_AM_REALLY_STUPID=1 python3 -c 'open(\"f\",\"w\").write(s)'",
        "the override, as a leading assignment",
    ),
    (
        "env I_AM_REALLY_STUPID=1 python3 -c 'open(\"f\",\"w\").write(s)'",
        "the override through env, where the parser drops assignments",
    ),
    (
        "I_AM_REALLY_STUPID=1 python3 - <<'PY'\nopen('f','w').write('x')\nPY",
        "the override on the heredoc form",
    ),
]

DENY = [
    (_THE_HABIT, "the exact shape tools.md names"),
    ("python3 -c 'open(\"f\",\"w\").write(s)'", "the one-liner form"),
    (
        "python3 -c \"import re; s=open('f').read(); open('f','w').write(s.replace('a','b'))\"",
        "read, replace, write back",
    ),
    (
        "python3 - <<'PY'\nimport pathlib\npathlib.Path('f').write_text('x')\nPY",
        "pathlib instead of open",
    ),
    (
        "python3 <<'EOF'\nopen('f', 'a').write('x')\nEOF",
        "no dash, still reads the program from stdin",
    ),
    ("python3 -c 'import os; os.replace(\"a\",\"b\")'", "a rename is an edit"),
    ("python3 -c 'import shutil; shutil.copy(\"a\",\"b\")'", "so is a copy"),
    ("sudo python3 -c 'open(\"/etc/f\",\"w\").write(x)'", "behind a prefix runner"),
    ("python3.12 -c 'open(\"f\",\"w\")'", "a versioned interpreter"),
    ("/usr/bin/python -c 'open(\"f\",\"w\")'", "by absolute path"),
    # The bug the override turned up: any assignment used to hide the
    # interpreter from the parser, so every one of these was an accidental
    # override of exactly the kind the named one is supposed to be.
    ("FOO=1 python3 -c 'open(\"f\",\"w\")'", "an unrelated assignment is not a way out"),
    (
        "I_AM_REALLY_STUPID=0 python3 -c 'open(\"f\",\"w\")'",
        "the override's own name with the wrong value",
    ),
    ("PYTHONPATH=src python3 -c 'open(\"f\",\"w\")'", "a real, ordinary assignment"),
]


def load(path):
    loader = importlib.machinery.SourceFileLoader("block_python_edit", path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path to pretooluse-block-python-edit.py>", file=sys.stderr)
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
            if got != want_denied:
                failures += 1
                shown = command.replace("\n", "\\n")
                print(
                    f"FAIL: expected {label} but got {'deny' if got else 'allow'}: "
                    f"{shown}  [{why}]",
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
