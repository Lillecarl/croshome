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
async def send(text: str, press_enter: bool = True) -> str:
    """Type text into this session's stdin, then press Enter.

    The text is typed a few characters at a time with a short randomized
    delay between chunks, and Enter follows after its own delay, rather than
    everything arriving in one burst — apps that distinguish typed input
    from a paste (Claude Code's own input box included) can tell an instant
    burst apart from real typing and won't submit it as a live command. This
    call doesn't return until typing has actually finished, so "ok" means
    the text is in, not that it's on its way.

    Args:
        text: The text to type.
        press_enter: Press Enter after typing (default True).
    """
    return await call(_session_id(), "send", {"text": text, "press_enter": press_enter})


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
    marks the session as needing the user (the Stop hook won't nudge you to
    keep going) and records the request. Once your turn actually ends,
    "/compact [instructions]" is typed for real, and you'll be resumed
    automatically afterwards with a fresh "Continue with your task." prompt.

    Do not call any more tools or produce more text after this -- just stop.

    Refuses (raising an error) if this session's context usage is below the
    configured minimum, since compacting a mostly empty context throws away
    history for no benefit.

    Args:
        instructions: What to preserve/focus on across the compaction, passed
            straight through to /compact. Leave empty for a plain /compact.
    """
    return await call(_session_id(), "compact", {"instructions": instructions})


def main():
    mcp.run()


if __name__ == "__main__":
    main()
