"""Showing what the model is doing while it does it.

A request that reads four files and greps the docs before answering looks,
without this, exactly like a request that hung. The file tools are silent by
design -- they need no approval -- so silence is the default state and that is
the problem.

What it says goes through `terminal.write` rather than `print`, because the
agent runs on a worker thread and these lines therefore arrive while the user
may be halfway through typing something. That module decides whether there is a
prompt to write underneath; everything here just hands over text.

Everything ends up on stderr, so a `: ...` line piped somewhere still yields
only the answer.

Nothing here imports pydantic-ai at module scope; the event classes are matched
by their `event_kind` discriminator instead, which is a documented part of the
message API and costs no import.
"""

from __future__ import annotations

import sys

from .terminal import write

#: Kept short and dim. This is scaffolding around an answer, not the answer.
_DIM = "\x1b[2m"
_RESET = "\x1b[0m"

#: Arguments worth naming in a one-line summary, per tool. Anything else is
#: summarised by its size, because a tool call that pastes a file into `content`
#: must not paste it onto the terminal too.
_INTERESTING = (
    "path",
    "pattern",
    "page",
    "query",
    "include_glob",
    "name",
    "old_text",
)

#: `run_xonsh` announces itself through its own approval prompt, which shows the
#: full code. Repeating it here would print everything twice.
_SILENT = frozenset({"run_xonsh"})


def _colour() -> bool:
    """Dim text only where it will render as dim text."""
    try:
        return sys.stderr.isatty()
    except (AttributeError, ValueError):
        return False


def describe(name: str, args) -> str:
    """A one-line summary of a tool call, short enough to be scannable."""
    if not isinstance(args, dict):
        args = {}
    for key in _INTERESTING:
        if key in args and isinstance(args[key], str):
            value = args[key]
            if len(value) > 60:
                value = value[:57] + "..."
            return f"{name} {value}"
    if not args:
        return name
    # No obviously nameable argument: say how big it was instead of what it was.
    sizes = ", ".join(
        f"{k}={len(v)}c" if isinstance(v, str) else f"{k}" for k, v in args.items()
    )
    return f"{name} ({sizes})"


def note(line: str) -> None:
    """Write one activity line."""
    if _colour():
        write(f"{_DIM}· {line}{_RESET}\n")
    else:
        write(f"· {line}\n")


def handler():
    """An `event_stream_handler` for `Agent.run_sync`.

    pydantic-ai hands over an async iterable of events per model request. Only
    tool calls are reported: token deltas would redraw the line constantly for
    no information, and the final answer is printed by the caller anyway.
    """

    from .files import ERROR

    async def show(_ctx, events) -> None:
        async for event in events:
            kind = getattr(event, "event_kind", None)
            if kind == "function_tool_call":
                part = getattr(event, "part", None)
                name = getattr(part, "tool_name", "") or "tool"
                if name in _SILENT:
                    continue
                args = getattr(part, "args_as_dict", None)
                note(describe(name, args() if callable(args) else args))
            elif kind == "function_tool_result":
                # Only failures. A successful read is already accounted for by
                # the line above it, and its contents are not the user's
                # problem -- but a call that failed and is about to be retried
                # looks, without this, like the same action happening twice for
                # no reason.
                content = getattr(getattr(event, "result", None), "content", None)
                if isinstance(content, str) and content.startswith(ERROR):
                    note(f"  {content[len(ERROR) :].splitlines()[0][:100]}")

    return show


#: A write is worth seeing; a whole file scrolling past is not. Long diffs are
#: cut here and the count reported instead.
MAX_DIFF_LINES = 40

_GREEN = "\x1b[32m"
_RED = "\x1b[31m"


def diff(path: str, before: str, after: str) -> None:
    """Show what an edit changed, as a bounded unified diff.

    Reads are summarised by their path alone -- the file's contents are the
    model's business and would bury the terminal. A *write* is different: it
    changed something of the user's, and they should be able to see what without
    going to `git diff`.

    `path` is not printed: the tool-call line immediately above already names
    it. It is taken anyway so that the caller cannot forget it belongs here if
    that ever stops being true.
    """
    import difflib

    body = [
        line
        for line in difflib.unified_diff(
            before.splitlines(), after.splitlines(), lineterm="", n=2
        )
        # Our own header below is more useful than ---/+++ of an unnamed file.
        if not line.startswith(("---", "+++"))
    ]
    if not body:
        return

    colour = _colour()
    shown = []
    for line in body[:MAX_DIFF_LINES]:
        if not colour:
            shown.append(f"  {line}")
        elif line.startswith("+"):
            shown.append(f"  {_GREEN}{line}{_RESET}")
        elif line.startswith("-"):
            shown.append(f"  {_RED}{line}{_RESET}")
        else:
            shown.append(f"  {_DIM}{line}{_RESET}")
    if len(body) > MAX_DIFF_LINES:
        trailer = f"  ... {len(body) - MAX_DIFF_LINES} more diff lines"
        shown.append(f"{_DIM}{trailer}{_RESET}" if colour else trailer)
    # One write, not one per line: a diff is a block, and a prompt redrawing
    # through the middle of it would interleave the prompt with the hunk.
    write("\n".join(shown) + "\n")
