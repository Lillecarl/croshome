#!/usr/bin/env python3
"""PreToolUse hook: refuses a file edit written as inline Python.

home/agents/shared/tools.md is the policy, and it has the reasons: a
`python3 - <<'PY'` block doing `src.replace(...)` leaves no diff to read, does
not fail when the anchor text is wrong, and leaves nothing anyone can run
again. The file-editing tools fail loudly on a bad anchor. `pyedit` does the
same job as the script for the cases those tools are clumsy at -- several
files at once, one file in many places -- and it stages edits in memory, shows
them as dry-run diffs, and writes only on --apply.

**Two conditions, and both must hold.** The Python has to be inline -- `-c`,
or a heredoc fed to the interpreter -- *and* it has to write something. That
scoping is the whole design:

  python3 build.py                     allowed, a program in the repository
  python3 -c 'import json; print(...)'  allowed, inline but reads
  python3 -c 'open(f,"w").write(s)'     refused
  python3 - <<'PY' ... open(...,"w")    refused

Running a project's own Python is ordinary work and must not be caught: the
thing being refused is source code smuggled through the shell to rewrite a
file, not the language. A read-only one-liner is how half of an investigation
gets done, so `print`, `sys.stdout.write` and friends stay out of the way.

**The heredoc body is searched, not stripped.** The sibling hooks strip it
because a body is data that must not read as a command. Here the body IS the
program, so it is exactly what has to be read.

**The way out is deliberate.** `I_AM_REALLY_STUPID=1` anywhere in the command
allows it. The name is the point: it is a decision somebody takes on purpose
and can be found in a transcript afterwards, not a flag to paste by habit. The
refusal text does not advertise it, for the same reason.

**What it does not see.** A script written to a file first and then run, and
any command assembled somewhere else. Same gap the sibling hooks name, and
deliberate for the same reason: this makes the common form fail loudly with a
better tool named in the refusal. It is not a boundary.
"""

import json
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))

_INTERPRETERS = re.compile(r"\Apython(?:\d+(?:\.\d+)?)?\Z|\Apypy\d*\Z")

# The deliberate way out. Named so that using it is a decision somebody makes
# on purpose and can be found later in a transcript, rather than a flag that
# gets pasted in by habit.
#
# It is honoured wherever it appears as its own token, not only as the leading
# assignment, because `env VAR=1 python3 ...` loses it: the sibling parser
# drops env's assignments while stripping the runner. An opt-out that works in
# one spelling and silently fails in another is worse than none.
_OVERRIDE = "I_AM_REALLY_STUPID=1"

# A leading VAR=value on a command. These have to come off before argv[0] is
# the interpreter -- without that, ANY assignment prefix hid the python from
# this hook and allowed the edit. Found by writing the override and watching
# an unrelated `FOO=1 python3 -c ...` sail through the same way.
_ASSIGNMENT = re.compile(r"\A[A-Za-z_][A-Za-z0-9_]*=")

# Writing to stdout or stderr is output, not a file edit, and a read-only
# one-liner uses it freely. Removed before the search below so it cannot
# trigger the .write( pattern.
_STREAM_WRITES = re.compile(r"\bsys\.(?:stdout|stderr)\.(?:write|writelines)\b")

# What makes a snippet an edit rather than a read.
_WRITES = (
    # open(..., "w") and friends -- any mode that is not purely reading.
    re.compile(r"""\bopen\s*\([^)]{0,300}?['"][rbtU+]*[wax][rbtU+]*['"]"""),
    re.compile(r"\.write_text\s*\(|\.write_bytes\s*\("),
    re.compile(r"\.writelines\s*\(|\.write\s*\("),
    re.compile(r"\bos\.(?:replace|rename|remove|unlink|truncate|ftruncate)\s*\("),
    re.compile(r"\bshutil\.(?:move|copy|copy2|copyfile|copytree|rmtree)\s*\("),
    re.compile(r"\.truncate\s*\(|\.unlink\s*\(|\.mkdir\s*\(|\.rename\s*\("),
    re.compile(r"\bfileinput\b[^\n]{0,200}\binplace\b"),
    re.compile(r"\bPath\s*\([^)]{0,200}\)\s*\.\s*(?:write_text|write_bytes|unlink)"),
)

_HEREDOC_BODY = re.compile(
    r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n(.*?)^[ \t]*\2[ \t]*$",
    re.DOTALL | re.MULTILINE,
)

_REFUSAL = (
    "This rewrites a file with inline Python. It leaves no diff to read, it "
    "does not fail when the anchor text is wrong, and it leaves nothing "
    "anyone can run again -- see home/agents/shared/tools.md. Use the "
    "file-editing tools, which fail loudly on a bad anchor. For an edit they "
    "are clumsy at -- several files at once, or one file in many places -- "
    "use `pyedit`: same job, staged in memory, shown as a dry-run diff, "
    "written only on --apply. Run `pyedit skill` once for its instructions "
    "rather than guessing at the interface. Running a .py file in the "
    "repository is not affected."
)


def _load_git_write_hook():
    """The sibling shell parser, or None when it cannot be found. Same lookup
    as pretooluse-block-trailers.py -- see ../../../agents.nix for why all of
    them land in one bin/."""
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


def _strip_assignments(argv):
    while argv and _ASSIGNMENT.match(argv[0]):
        argv = argv[1:]
    return argv


def _edits_a_file(source):
    text = _STREAM_WRITES.sub(" ", source)
    return any(pattern.search(text) for pattern in _WRITES)


def _inline_sources(command, parser):
    """Every piece of Python this command supplies inline: the argument to
    -c, and the body of a heredoc fed to an interpreter."""
    sources = []

    tokens = parser._tokenize(parser._strip_heredoc_bodies(command))
    if tokens is None:
        return sources
    if _OVERRIDE in tokens:
        return sources  # asked for, in as many words

    reads_stdin = False
    for argv in parser._argvs(tokens):
        # Assignments first, then runners, then assignments again: an
        # invocation can carry both, in either order (`FOO=1 sudo python3`,
        # `sudo FOO=1 python3`).
        argv = _strip_assignments(parser._strip_prefix_runners(argv))
        argv = parser._strip_prefix_runners(argv)
        if not argv:
            continue
        if not _INTERPRETERS.match(os.path.basename(argv[0])):
            continue

        for i, token in enumerate(argv[1:], start=1):
            if token == "-c" and i + 1 < len(argv):
                sources.append(argv[i + 1])
        # `python3 -`, and `python3` with nothing to run, both read the
        # program from stdin -- which is where the heredoc goes.
        if "-" in argv[1:] or all(token.startswith("-") for token in argv[1:]):
            reads_stdin = True

    if reads_stdin:
        sources.extend(match.group(3) for match in _HEREDOC_BODY.finditer(command))

    return sources


def _denied(command, parser):
    return any(_edits_a_file(source) for source in _inline_sources(command, parser))


def main():
    hook_input = json.load(sys.stdin)
    if hook_input.get("tool_name") != "Bash":
        return

    parser = _load_git_write_hook()
    if parser is None:
        # Without the parser there is no safe way to tell an interpreter in
        # command position from the word in a sentence. Allow.
        return

    if not _denied(hook_input.get("tool_input", {}).get("command", ""), parser):
        return

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": _REFUSAL,
        }
    }))


if __name__ == "__main__":
    main()
