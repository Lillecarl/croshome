"""Claude Code statusline command. Reports the full stats payload to the
wrapty control socket (when running under wrapty) and prints a short
status line."""

import asyncio
import json
import sys
import os

from wrapty_client import call


def _render(payload):
    model = payload.get("model", {}).get("display_name", "?")
    ctx = payload.get("context_window", {})
    used_pct = ctx.get("used_percentage")
    cost = payload.get("cost", {}).get("total_cost_usd")

    parts = [model]
    if used_pct is not None:
        parts.append(f"ctx {used_pct:.0f}%")
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
