"""Minimal MCP server that talks to a running wrapty session's control
socket: sends text to the wrapped process's stdin, and reads back the
context/usage stats its statusline has reported.

Runs as a subprocess of the Claude Code session wrapty wrapped, so it
inherits WAPTY_ID from the environment automatically -- there is exactly one
session it could mean, so tools don't take a session id."""

import os

from mcp.server.fastmcp import FastMCP

from wrapty_client import call

mcp = FastMCP("wrapty")


def _session_id() -> str:
    wapty_id = os.environ.get("WAPTY_ID")
    if not wapty_id:
        raise RuntimeError("Not running under wrapty (WAPTY_ID is not set).")
    return wapty_id


@mcp.tool()
async def send(text: str, press_enter: bool = True, resume: str | None = None) -> str:
    """Type text into this session's stdin, then press Enter.

    The text is typed a few characters at a time with a short randomized
    delay between chunks, and Enter follows after its own delay, rather than
    everything arriving in one burst — apps that distinguish typed input
    from a paste (Claude Code's own input box included) can tell an instant
    burst apart from real typing and won't submit it as a live command. This
    call doesn't return until typing has actually finished, so "ok" means
    the text is in, not that it's on its way.

    Typed is not the same as run. This session only submits queued input
    once it is idle, so anything you type into your own box lands in the box
    and waits for your turn to end. If you keep working, it keeps waiting —
    and the Stop hook nudging you onward is exactly what stops your turn
    ending, so the text can sit there indefinitely and never take effect.

    Pass `resume` whenever you are sending a command you expect to act on
    this session — a slash command like /reload-plugins, say. It permits the
    next Stop and says what to type back to you once your queued input has
    gone through, so: your turn ends, the command runs, and you are started
    again with that text as a fresh prompt. Put enough in it to pick the
    work back up, since it arrives with no other context.

    Then actually stop your turn. Nothing runs until you do.

    A slash command reports its result in the transcript rather than
    anywhere pollable, so being resumed is not proof it worked — check for
    the effect you wanted once you are back.

    Args:
        text: The text to type.
        press_enter: Press Enter after typing (default True).
        resume: What to type back to you after the turn ends, or None (the
            default) to just type and leave your turn alone.
    """
    return await call(
        _session_id(),
        "send",
        {"text": text, "press_enter": press_enter, "resume": resume},
    )


@mcp.tool()
async def get_stats() -> dict:
    """Get the most recent context/usage stats reported by this session's
    statusline."""
    return await call(_session_id(), "get_stats")


@mcp.tool()
async def need_user() -> str:
    """Flag that the agent is now blocked on the user (e.g. it finished
    everything it can do autonomously, or needs a decision). Clears the
    Stop-nudge counter so the next Stop is not treated as a silent one."""
    return await call(_session_id(), "need_user")


@mcp.tool()
async def compact(instructions: str = "") -> str:
    """Schedule a context compaction and stop your turn now.

    This session's input box only accepts a typed "/compact" as a genuine
    command when it's actually idle -- not while you're still mid-turn
    running this very tool call. So this doesn't type it immediately: it
    records the request and permits your turn to end (the Stop hook won't
    nudge you to keep going). Once your turn actually ends,
    "/compact [instructions]" is typed for real.

    You're then resumed automatically, but not until the compaction has
    demonstrably happened: wrapty polls the statusline until the context
    usage it reports actually drops, and only then types a fresh "Continue
    with your task." prompt. Waiting on the effect rather than on having
    typed the keystrokes is the whole point -- you come back to a context
    that really is compacted, not to one where /compact merely got
    submitted. If the usage never drops, it gives up after a couple of
    minutes and resumes you anyway rather than stranding the session.

    Do not call any more tools or produce more text after this -- just stop.

    Refuses (raising an error) if this session's context usage is below the
    configured minimum, since compacting a mostly empty context throws away
    history for no benefit.

    Args:
        instructions: What to preserve/focus on across the compaction, passed
            straight through to /compact. One line is enough -- what comes
            next and anything that must survive it; the summary reads the
            whole conversation anyway. Leave empty for a plain /compact.
    """
    return await call(_session_id(), "compact", {"instructions": instructions})


def main():
    mcp.run()


if __name__ == "__main__":
    main()
