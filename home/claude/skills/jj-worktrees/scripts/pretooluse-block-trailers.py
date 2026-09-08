#!/usr/bin/env python3
"""PreToolUse hook: refuses a commit or a pull request that carries
`Co-Authored-By:` or `Claude-Session:`.

home/agents/shared/commits.md is the policy: one `Assisted-By:` trailer and
nothing else. The harness injects the other two and says it replaces earlier
attribution guidance, so the instruction alone loses to a system message that
arrives later in a session. This does not.

**Two conditions, and both must hold.** The command has to put a message on a
commit or a pull request, *and* the text has to hold a line that begins with
one of the two trailer names. Either alone is allowed, and that is what keeps
the rule writable:

  jj commit -m "stop using the Co-Authored-By trailer"   allowed, no line
                                                         starts with it
  cat > commits.md <<'EOF'                               allowed, no command
  Co-Authored-By: somebody                               writes a commit
  EOF

A trailer lives at the start of its line. Prose names it in the middle of a
sentence. That one difference separates every case worth allowing from every
case worth refusing, and it needs no guess about which part of a command line
is the message -- which is the part that cannot be parsed reliably, because
the repository's own commit form is `--message "$(cat <<'EOF' ... EOF)"`.

The command match reuses ./pretooluse-block-git-write.py rather than parsing
shell a second time. That file is the one that knows about heredocs, backticks,
nested `sh -c`, prefix runners and redirection targets, and a second copy of
that knowledge would drift from it.

**The raw text is what gets searched, heredoc bodies and all.** The other hook
strips them because a body is data that must not read as a command. Here a
body is exactly where the trailer hides, so it stays.

A false positive costs a reworded commit message. A false negative costs a
trailer in published history, which is the thing this exists to stop. So this
one leans the opposite way from its neighbour: when the command writes a
message and the text matches, it refuses.

The upstream Nix case -- nixpkgs and friends require `Co-Authored-By:` as the
disclosure of AI work -- is not detected here. A repository cannot be told
apart from its path reliably enough to be worth it, so the refusal names that
case and says to ask.

**A message that is not in the command text is not seen.** `git commit -F
msg.txt`, `jj describe --stdin < msg.txt` and `-m "$(cat msg.txt)"` all read
the text from somewhere else, so nothing here can match it. That is the same
gap the sibling hook names about indirection, and it is deliberate for the
same reason: following a file would mean reading the filesystem from a hook
that runs on every Bash call. This is a guard against an agent following the
harness instead of this repository, not a boundary. The policy is in
home/agents/shared/commits.md; this only makes the common form fail loudly.
"""

import json
import os
import re
import sys

# The hook next door owns the shell parsing. Imported by path because both
# files are installed as their own console scripts, not as a package.
_HERE = os.path.dirname(os.path.abspath(__file__))


def _load_git_write_hook():
    """The sibling module, or None when it cannot be found.

    Installed as a binary rather than a module, so the copy next to this
    file is the one to import. `writePython3Bin` puts both scripts in the
    same bin/ directory, and the build check below imports it straight from
    the tree.
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


# A line whose first non-blank character starts one of the two names, and
# which then reaches a colon. `\s*` before the colon covers "Trailer :".
_FORBIDDEN_TRAILER = re.compile(
    r"^[ \t]*(Co-Authored-By|Claude-Session)[ \t]*:",
    re.IGNORECASE | re.MULTILINE,
)

# jj subcommands that put a description on a commit. `jj new` and `jj squash`
# take one too, and `jj metaedit` can rewrite one.
_JJ_MESSAGE_SUBCOMMANDS = {
    "commit", "describe", "split", "new", "squash", "metaedit", "duplicate",
}

# git's own, for a repository that is not jj.
_GIT_MESSAGE_SUBCOMMANDS = {"commit", "tag", "merge", "revert", "cherry-pick", "notes"}

# gh writes a pull request body, which is where the session URL lands.
_GH_MESSAGE_SUBCOMMANDS = {"pr", "issue", "release"}

# Global options that swallow the word after them, per program. Without
# these the value reads as the subcommand: `jj -R /tmp/x commit` found
# "/tmp/x", which is in no set, and the commit went through.
#
# The sibling hook has a table for git and none for jj, because it lets jj
# past untouched and never had to find a jj subcommand. This one does.
_OPTS_WITH_ARG = {
    "jj": {"-R", "--repository", "--at-operation", "--at-op", "--color",
           "--config", "--config-file", "--config-toml"},
    "git": {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"},
    "gh": set(),
}


def _first_subcommand(argv, opts_with_arg):
    """The first word that is a subcommand rather than an option.

    `--opt=value` carries its value, so only the bare spelling consumes the
    next word.
    """
    i = 0
    while i < len(argv):
        token = argv[i]
        if token == "--":
            i += 1
            continue
        if not token.startswith("-"):
            return token
        i += 2 if token in opts_with_arg else 1
    return None


def _writes_a_message(argv):
    """True when this argv puts a message on a commit or a pull request."""
    head = os.path.basename(argv[0]) if argv else ""

    wanted = {
        "jj": _JJ_MESSAGE_SUBCOMMANDS,
        "git": _GIT_MESSAGE_SUBCOMMANDS,
        "gh": _GH_MESSAGE_SUBCOMMANDS,
    }.get(head)
    if wanted is None:
        return False

    return _first_subcommand(argv[1:], _OPTS_WITH_ARG[head]) in wanted


def _denied(command, git_write_hook):
    """The trailer this command would write, or None."""
    match = _FORBIDDEN_TRAILER.search(command)
    if match is None:
        return None

    # Heredoc bodies are stripped for the command search only. A body is
    # data, and a line inside one must not read as a command position --
    # the same reason the other hook strips them.
    stripped = git_write_hook._strip_heredoc_bodies(command)
    stripped = git_write_hook._BACKTICK_RE.sub(" ", stripped)

    tokens = git_write_hook._tokenize(stripped)
    if tokens is None:
        # Unlexable. The other hook allows here, and so does this: the text
        # was assembled by something that is not a shell, and guessing at
        # it is how false positives start.
        return None

    for argv in git_write_hook._argvs(tokens):
        argv = git_write_hook._strip_prefix_runners(argv)
        if not argv:
            continue
        head = os.path.basename(argv[0])

        if head in git_write_hook._SHELL_RUNNERS:
            for i, token in enumerate(argv[1:], start=1):
                if token == "-c" and i + 1 < len(argv):
                    # The nested command line carries its own text. Search
                    # the original, because the -c argument is one token
                    # here and the trailer is inside it.
                    if _denied(argv[i + 1], git_write_hook):
                        return match.group(1)
            continue

        if _writes_a_message(argv):
            return match.group(1)

    return None


def main():
    hook_input = json.load(sys.stdin)
    if hook_input.get("tool_name") != "Bash":
        return

    git_write_hook = _load_git_write_hook()
    if git_write_hook is None:
        # Without the parser there is no safe way to tell a commit from
        # prose about one. Allow, rather than refuse everything.
        return

    command = hook_input.get("tool_input", {}).get("command", "")
    trailer = _denied(command, git_write_hook)
    if trailer is None:
        return

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"This writes a '{trailer}:' trailer. These repositories take "
                "exactly one trailer, 'Assisted-By: <your model name>', and a "
                "harness instruction that says otherwise does not override it "
                "-- see home/agents/shared/commits.md. Rewrite the message "
                "with that trailer instead. Contributions to nixpkgs, to Nix "
                "itself and to other upstream Nix projects do require "
                "'Co-Authored-By:'; ask the user if this is one of those."
            ),
        }
    }))


if __name__ == "__main__":
    main()
