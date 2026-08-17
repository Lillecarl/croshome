#!/usr/bin/env python3
"""PreToolUse hook: blocks git subcommands that can write repository state,
in jj-colocated repos. jj is the actual version control workflow here, so a
stray "git commit"/"push"/etc from an agent bypasses it entirely.

Allowlist-based (deny unless known read-only), not a denylist of write
commands: git's write surface (commit, merge, push, switch, checkout,
rebase, reset, add, rm, mv, stash, tag, branch, cherry-pick, revert,
remote, config, clean, gc, fetch, pull, am, apply, worktree, submodule,
filter-branch, ...) is too large and too easy to miss a new one from. The
read-only surface is small and doesn't grow. Dual-mode commands (branch,
tag, stash, remote, config, reflog) are left off entirely rather than
trying to tell their read and write forms apart.

"jj git <subcommand>" is jj's own git-interop subcommand (push, fetch,
clone, ...), not the git CLI -- it goes through jj's own safety model, so
it's exempt.
"""

import json
import os
import re
import shlex
import subprocess
import sys

_READONLY_GIT_SUBCOMMANDS = {
    "status", "log", "show", "diff", "diff-tree", "diff-index", "diff-files",
    "blame", "annotate", "cat-file", "ls-files", "ls-tree", "ls-remote",
    "rev-parse", "rev-list", "describe", "shortlog", "help", "version",
    "grep", "count-objects", "fsck", "merge-base", "show-ref", "var",
    "check-ignore", "check-attr", "check-mailmap", "range-diff",
}

# Global git options that consume the following token as their value, so
# that value isn't mistaken for the subcommand.
_GIT_OPTS_WITH_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}

# Matches "git" as a standalone command word (not a suffix like "legit" or
# "digit"), including invocation by full path ("/usr/bin/git"). A word-char
# lookbehind, not a whitespace one, so the path-prefix case still matches.
_GIT_CALL_RE = re.compile(r"(?<!\w)git(?=[\s;&|`)]|$)")

# Where a git invocation's argument list ends: the next shell control
# character, or the start of a new command substitution.
_GIT_STOP_RE = re.compile(r"[;&|`)\n]|\$\(")

# A "git" match immediately preceded by "jj" is jj's own subcommand, not a
# real git invocation -- see module docstring.
_JJ_GIT_PREFIX_RE = re.compile(r"(?<!\w)jj\s+$")


def _first_positional(tokens):
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "--":
            i += 1
            continue
        if not tok.startswith("-"):
            return tok
        i += 2 if tok in _GIT_OPTS_WITH_ARG else 1
    return None


def _denied_git_command(command):
    """The offending "git <subcommand>" string if `command` invokes a git
    subcommand outside the read-only allowlist, else None. Scans the raw
    command text for "git" rather than parsing full shell grammar, so it
    also catches invocations nested inside `sh -c '...'`, backticks, or
    `$(...)` -- those hide from a top-level shlex.split but not from a text
    scan. Erring towards over-blocking is fine here; the point is that
    nothing writes, not that every legitimate read-only call is recognized."""
    for m in _GIT_CALL_RE.finditer(command):
        if _JJ_GIT_PREFIX_RE.search(command[: m.start()]):
            continue
        rest = command[m.end():]
        stop = _GIT_STOP_RE.search(rest)
        segment = rest[: stop.start()] if stop else rest
        try:
            tokens = shlex.split(segment)
        except ValueError:
            tokens = segment.split()  # unbalanced quote, e.g. cut off at `stop` -- best effort
        sub = _first_positional(tokens)
        if sub is not None and sub not in _READONLY_GIT_SUBCOMMANDS:
            return f"git {sub}"
    return None


def _is_jj_repo(cwd):
    try:
        subprocess.run(
            ["jj", "root"],
            cwd=cwd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False
    return True


def main():
    hook_input = json.load(sys.stdin)
    if hook_input.get("tool_name") != "Bash":
        return

    command = hook_input.get("tool_input", {}).get("command", "")
    offending = _denied_git_command(command)
    if offending is None:
        return

    # Only spawn jj once an actual write subcommand is found -- most Bash
    # calls never mention git at all, and shouldn't pay for this.
    cwd = hook_input.get("cwd") or os.getcwd()
    if not _is_jj_repo(cwd):
        return

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"'{offending}' can write to the repository. This repo uses jj -- "
                "use jj instead (jj git push/fetch cover the git-interop cases), "
                "or ask the user if you specifically need this git command."
            ),
        }
    }))


if __name__ == "__main__":
    main()
