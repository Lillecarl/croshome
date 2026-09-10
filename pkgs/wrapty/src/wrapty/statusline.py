"""Claude Code statusline command. Reports the full stats payload to the
wrapty control socket (when running under wrapty) and prints a short
status line."""

import asyncio
import json
import sys
import os
import time

from wrapty.client import call

# Above this, a window is close enough to full that the time to its reset
# changes what you do next. Below it the reset is noise, so the line omits it.
LOUD_AT = 80

# The plan windows Claude Code reports, in the order they run out.
WINDOWS = (
    ("five_hour", "5h"),
    ("seven_day", "7d"),
)


def _until(epoch, now):
    """The time to `epoch`, largest unit first, with the zero units left out:
    `2d3h`, `23h59m`, `45m`. A unit that is zero says nothing, so `1d` never
    prints as `1d0h`.

    One unit alone was too coarse to act on: "2d" covered anything from two
    days to nearly three. Two units is the whole of it -- once the answer is
    in days, the minutes change nothing you would do, so they drop."""
    seconds = int(epoch - now)
    if seconds <= 0:
        return "now"

    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes = seconds // 60

    units = [(days, "d"), (hours, "h")]
    if not days:
        units.append((minutes, "m"))

    parts = [f"{value}{unit}" for value, unit in units if value]
    # Under a minute every part is zero, and "0m" would read as "already
    # reset" when the reset has not happened yet.
    return "".join(parts) or "<1m"


def _window(data, label, now):
    """One plan window as `5h 62%`, with the reset time once it is loud."""
    if not data:
        return None
    pct = data.get("used_percentage")
    if pct is None:
        return None
    text = f"{label} {pct:.0f}%"
    resets_at = data.get("resets_at")
    if pct >= LOUD_AT and resets_at is not None:
        text += f" ({_until(resets_at, now)})"
    return text


def _render(payload, now=None):
    model = payload.get("model", {}).get("display_name", "?")
    ctx = payload.get("context_window", {})
    used_pct = ctx.get("used_percentage")
    limits = payload.get("rate_limits") or {}
    cost = payload.get("cost", {}).get("total_cost_usd")
    now = time.time() if now is None else now

    parts = [model]
    if used_pct is not None:
        parts.append(f"ctx {used_pct:.0f}%")
    # An API key has no plan windows, and an older Claude Code does not report
    # them, so every one of these is optional.
    for key, label in WINDOWS:
        window = _window(limits.get(key), label, now)
        if window is not None:
            parts.append(window)
    if cost is not None:
        parts.append(f"${cost:.2f}")
    return " · ".join(parts)


async def _report(payload):
    wapty_id = os.environ.get("WAPTY_ID")
    if not wapty_id:
        return
    try:
        await call(wapty_id, "stats", {"data": payload})
    except Exception:
        pass  # best-effort; never let stats reporting break the status line


def main():
    payload = json.load(sys.stdin)
    asyncio.run(_report(payload))
    print(_render(payload))


if __name__ == "__main__":
    main()
