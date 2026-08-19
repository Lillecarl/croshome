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

This parses the command into shell words and only considers words in
*command position* -- the start of the command, or just after a separator
like ; && || |. An earlier version scanned the raw text for "git" anywhere,
which caught nested invocations but also fired on any text that merely
mentioned the tool: a commit message, a heredoc body, a grep pattern. That
was not a hypothetical annoyance -- writing the paragraph about this hook in
../../../../AGENTS.md was refused twice.

Nesting is still caught, because the things that actually introduce nested
shell are handled explicitly rather than by scanning:

  sh -c '...' / bash -c '...'     the -c argument is parsed as a command
  $(...)                          shlex yields "(" as its own token
  `...`                           extracted and parsed before tokenizing
  env/sudo/... git push           prefix runners are stripped

"jj" in command position is left alone entirely. jj's git-interop
subcommand (jj git push/fetch/clone) goes through jj's own safety model,
and this no longer has to reason about which of jj's global options might
sit between "jj" and "git".

A false positive costs more than a false negative here, and the code
resolves every doubt that way. This is a guard against an agent forgetting
which VCS the repo uses, not a security boundary: anything determined to
run git can trivially get past it, so buying a little more coverage at the
price of refusing legitimate commands is a bad trade. Concretely, anything
that cannot be lexed is allowed rather than blocked, and no attempt is made
to chase indirection like `jj util exec --`.
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

# Tokens after which the next word is a new command rather than an argument.
# Redirections are deliberately absent -- what follows ">" is a filename, and
# a file called "git" is not an invocation.
_COMMAND_SEPARATORS = {";", "&&", "||", "|", "|&", "&", "(", ")", "{", "}", "!", "\n"}

# What follows one of these is a redirection target, so skip it: `cat > git`
# names a file.
_REDIRECTS = {">", ">>", "<", "<<", "<<<", ">&", "<&", "&>", ">|"}

# Wrappers that run another command, with their own options first. Stripping
# them exposes the real command word underneath.
_PREFIX_RUNNERS = {
    "env", "sudo", "doas", "command", "builtin", "exec", "nohup", "nice",
    "ionice", "setsid", "stdbuf", "time", "timeout", "xargs", "watch",
}

# Shells whose -c argument is itself a command line.
_SHELL_RUNNERS = {"sh", "bash", "zsh", "dash", "ksh", "ash", "fish", "busybox"}

# A heredoc introducer and its delimiter word: <<EOF, <<-EOF, <<'EOF', <<"EOF".
_HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

# `...` command substitution. Non-greedy, and escaped backticks do not close.
_BACKTICK_RE = re.compile(r"`([^`]*)`")


def _strip_heredoc_bodies(command):
    """Remove the body of every heredoc, keeping the command line itself.

    A heredoc body is data. Left in place its lines tokenize like any other
    words, and a line that happens to start with a separator would read as a
    command position -- which is how documentation about this hook got
    refused by it.
    """
    for match in _HEREDOC_RE.finditer(command):
        delimiter = match.group(2)
        # The body starts on the line after the introducer and ends at the
        # first line that is exactly the delimiter (ignoring surrounding
        # whitespace, which covers the <<- indented form).
        body = re.compile(
            r"(?<=\n)(.*?\n)?[ \t]*" + re.escape(delimiter) + r"[ \t]*(?=\n|$)",
            re.DOTALL,
        )
        tail = body.search(command, match.end())
        if tail:
            command = command[: tail.start()] + command[tail.end():]
    return command


def _tokenize(command):
    """Shell words for `command`, with separators as their own tokens.

    Returns None when the text cannot be lexed -- an unbalanced quote, most
    often because the command was assembled by something other than a shell.
    """
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:
        return None


def _argvs(tokens):
    """Split a token list into one argv per command position."""
    commands, current, skip_next = [], [], False
    for token in tokens:
        if skip_next:
            skip_next = False
            continue
        if token in _REDIRECTS:
            skip_next = True
            continue
        if token in _COMMAND_SEPARATORS:
            if current:
                commands.append(current)
            current = []
            continue
        current.append(token)
    if current:
        commands.append(current)
    return commands


def _strip_prefix_runners(argv):
    """Drop wrapper commands so the real command word is argv[0].

    For `env`, assignments of the form VAR=value precede the command too.
    """
    while argv:
        head = os.path.basename(argv[0])
        if head not in _PREFIX_RUNNERS:
            return argv
        argv = argv[1:]
        if head == "env":
            while argv and "=" in argv[0] and not argv[0].startswith("-"):
                argv = argv[1:]
        while argv and argv[0].startswith("-"):
            argv = argv[1:]
    return argv


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


def _denied_in(command, depth=0):
    """The offending "git <subcommand>" for `command`, or None.

    Recurses into nested shell, bounded because a hook that hangs or blows
    the stack on a hostile string is worse than one that misses a case.
    """
    if depth > 4:
        return None

    command = _strip_heredoc_bodies(command)

    # Backticks first: shlex has no notion of them, so their contents would
    # otherwise be read as arguments of the surrounding command.
    for match in _BACKTICK_RE.finditer(command):
        found = _denied_in(match.group(1), depth + 1)
        if found:
            return found
    command = _BACKTICK_RE.sub(" ", command)

    tokens = _tokenize(command)
    if tokens is None:
        # Unlexable, so there is no command position to speak of. Allow it:
        # guessing from raw text is exactly what produced the false
        # positives this replaced.
        return None

    for argv in _argvs(tokens):
        argv = _strip_prefix_runners(argv)
        if not argv:
            continue
        head = os.path.basename(argv[0])

        if head in _SHELL_RUNNERS:
            for i, tok in enumerate(argv[1:], start=1):
                if tok == "-c" and i + 1 < len(argv):
                    found = _denied_in(argv[i + 1], depth + 1)
                    if found:
                        return found
            continue

        # Anything jj runs is jj's business, `jj git push` included.
        if head == "jj":
            continue

        if head == "git":
            sub = _first_positional(argv[1:])
            if sub is not None and sub not in _READONLY_GIT_SUBCOMMANDS:
                return f"git {sub}"

    return None


def _denied_git_command(command):
    return _denied_in(command)


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
