#!/usr/bin/env python3
"""PreToolUse hook: refuses `pgrep`, `pkill -f` and `ps` piped into `grep`.

home/agents/shared/tools.md is the policy. The fault is measured, not
theoretical: the Bash tool runs the command inside a wrapper shell whose argv
holds the whole command text, so a pattern given to `-f` matches that shell.
`pgrep -af zzzUniquePatternZzz` printed the wrapper's own line. A
`while pgrep -f X` loop therefore never ends and the call hangs to its
timeout, which is a whole turn lost and a session that looks wedged.

`pkill -f X` is the same match with a signal behind it: the first thing it
kills is the shell running it. `ps` and a `grep` in one command is the same
match again -- and writing the snapshot to a file first does not help, because
the wrapper shell is in the snapshot either way.

**Scope, and why it differs between them.** Every `pgrep` is refused, which is
what the policy says and what keeps the rule one sentence long -- `pidof`
answers the exact-name question without the self-match. `pkill` is refused
only with `-f`, because `pkill -x some-daemon` is an ordinary way to stop a
process and nothing about it matches the caller.

**Command position only**, which is what makes the rule writable: a search for
the word, prose about it, and the policy file itself all still go through.

  grep -rn pgrep home/agents/       allowed, pgrep is an argument
  echo "no pgrep here"              allowed, same
  until ! pgrep -f X; do ...        refused

Deciding that is a shell parser, and ./pretooluse-block-git-write.py already
is one -- shlex with punctuation_chars, one argv per command position, prefix
runners stripped, backticks and `sh -c` followed. This imports it rather than
carrying a second copy that would drift from it, the same way
./pretooluse-block-trailers.py does. ../../../agents.nix puts all three in one
bin/, which is what makes the import resolve.

**What it does not see.** A command assembled somewhere else -- read from a
file, built by a script -- carries no text here to match. That is the same gap
the sibling hooks name, and it is deliberate for the same reason. This makes
the common form fail loudly with a reason; it is not a boundary.
"""

import json
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))

# The flag that makes pgrep and pkill read the whole command line, where the
# wrapper shell's copy of the pattern lives. Bundled spellings (-af, -fl) and
# the long one.
_FULL_LINE_FLAG = re.compile(r"\A(?:--full\Z|-(?!-)[a-zA-Z]*f)")

_GREPS = {"grep", "egrep", "fgrep"}

# Shell keywords that sit in front of a command word. The sibling parser
# splits on `!` but not on these, so `while pgrep -f X` arrives with "while"
# as argv[0] and the command word one place along.
_KEYWORDS = {
    "if", "then", "elif", "else", "fi", "while", "until", "do", "done",
    "case", "esac", "in", "for", "select", "function",
}

_MESSAGES = {
    "pgrep": (
        "`pgrep` matches the wrapper shell this command runs in -- its argv "
        "holds your pattern -- so the check never goes false and a loop on it "
        "hangs until the tool timeout."
    ),
    "pkill -f": (
        "`pkill -f` matches the wrapper shell this command runs in, so the "
        "first thing it kills is the shell running it."
    ),
    "ps and grep": (
        "`ps` searched with `grep` matches this command's own shell, whether "
        "the two are piped together or go through a file."
    ),
}


def _load_git_write_hook():
    """The sibling shell parser, or None when it cannot be found.

    Installed as a binary rather than a module, so the copy next to this file
    is the one to import -- same lookup as pretooluse-block-trailers.py.
    """
    import importlib.machinery
    import importlib.util

    for name in ("pretooluse-block-git-write.py", "jj-block-git-write"):
        path = os.path.join(_HERE, name)
        if not os.path.exists(path):
            continue
        loader = importlib.machinery.SourceFileLoader("_git_write_hook", path)
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        return module
    return None


def _strip_leading_words(argv, parser):
    """Everything before the real command word: shell keywords and the
    sibling's prefix runners, in whatever order they come -- `while sudo
    pgrep` has one of each."""
    while argv:
        stripped = parser._strip_prefix_runners(
            argv[1:] if argv[0] in _KEYWORDS else argv
        )
        if stripped == argv:
            return argv
        argv = stripped
    return argv


def _denied(command, parser, depth=0):
    """The program this command would run against itself, or None."""
    if depth > 3:
        return None  # a nesting this deep is not worth following

    # Backticks first: shlex has no notion of them, so their contents would
    # read as arguments of the surrounding command.
    text = parser._strip_heredoc_bodies(command)
    for match in parser._BACKTICK_RE.finditer(text):
        found = _denied(match.group(1), parser, depth + 1)
        if found:
            return found
    text = parser._BACKTICK_RE.sub(" ", text)

    tokens = parser._tokenize(text)
    if tokens is None:
        # Unlexable: assembled by something that is not a shell. Allow, the
        # same way the sibling does -- guessing from raw text is what
        # produces false positives.
        return None

    heads = []
    for argv in parser._argvs(tokens):
        argv = _strip_leading_words(argv, parser)
        if not argv:
            continue
        head = os.path.basename(argv[0])
        heads.append(head)

        if head in parser._SHELL_RUNNERS:
            for i, token in enumerate(argv[1:], start=1):
                if token == "-c" and i + 1 < len(argv):
                    found = _denied(argv[i + 1], parser, depth + 1)
                    if found:
                        return found
            continue

        if head == "pgrep":
            return "pgrep"
        if head == "pkill" and any(_FULL_LINE_FLAG.match(a) for a in argv[1:]):
            return "pkill -f"
        # Only a grep that runs after the ps can be searching its output.
        if head in _GREPS and "ps" in heads[:-1]:
            return "ps and grep"

    return None


def main():
    hook_input = json.load(sys.stdin)
    if hook_input.get("tool_name") != "Bash":
        return

    parser = _load_git_write_hook()
    if parser is None:
        # Without the parser there is no safe way to tell a command from
        # prose about one. Allow, rather than refuse everything.
        return

    program = _denied(hook_input.get("tool_input", {}).get("command", ""), parser)
    if program is None:
        return

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"{_MESSAGES[program]} See home/agents/shared/tools.md. For "
                "work you started, use run_in_background or a monitor and let "
                "it notify you. For a pid you hold, `kill -0 $pid`. For a "
                "process you did not start, `pidof <exe>`, or the state file, "
                "socket or API that answers the real question."
            ),
        }
    }))


if __name__ == "__main__":
    main()
