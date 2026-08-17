"""Claude Code hook scripts for wrapty's context-pressure nudge system.

Both hooks read the hook JSON from stdin and call into the wrapping wrapty
session's control socket via WAPTY_ID. If there's no WAPTY_ID (not running
under wrapty) or the socket call fails, they print nothing and exit clean.
The Stop hook, when it does nudge, genuinely blocks the stop (decision:
block) so the agent is forced to keep working rather than just seeing an
advisory message on its next turn. The PostToolUse hook only ever emits an
advisory systemMessage -- forcing a compaction isn't a "keep working" nudge
in the same sense, and could trap the agent mid-task. Its nudges are also
throttled by a cooldown (tracked in wrapty.py, shared across all tool calls
in the session) so a call that passes the probability roll doesn't fire on
every single tool call once pressure is high.
"""

import asyncio
import json
import os
import random
import sys

import jinja2

from wrapty_client import call

# Below LOW_WATERMARK_PCT, the PostToolUse hook never nudges. Between
# LOW_WATERMARK_PCT and MAX_CONTEXT_PCT, it nudges with linearly increasing
# probability. At/above MAX_CONTEXT_PCT, it nudges on every single call.
LOW_WATERMARK_PCT = float(os.environ.get("WRAPTY_LOW_WATERMARK_PCT", "50"))
MAX_CONTEXT_PCT = float(os.environ.get("WRAPTY_MAX_CONTEXT_PCT", "85"))

# Mirrors the compact tool's own floor in wrapty.py, so the Stop nudge only
# ever suggests a compaction the tool would actually accept.
MIN_COMPACT_PCT = float(os.environ.get("WRAPTY_MIN_COMPACT_PCT", "25"))

# On top of the probability roll, a nudge that would fire is also gated by a
# per-session cooldown, so pressure right at LOW_WATERMARK_PCT can't spam a
# nudge on every tool call. The cooldown itself shrinks as used_pct climbs
# toward MAX_CONTEXT_PCT, same linear ramp as the probability above.
NUDGE_COOLDOWN_MAX_SEC = float(os.environ.get("WRAPTY_NUDGE_COOLDOWN_MAX_SEC", "300"))
NUDGE_COOLDOWN_MIN_SEC = float(os.environ.get("WRAPTY_NUDGE_COOLDOWN_MIN_SEC", "20"))

_PROMPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompts")
_jinja_env = jinja2.Environment(
    loader=jinja2.FileSystemLoader(_PROMPTS_DIR),
    keep_trailing_newline=False,
)


def _render(template_name, **context):
    return _jinja_env.get_template(template_name).render(**context)


def _emit(system_message):
    print(json.dumps({"systemMessage": system_message}))


def _block(reason):
    print(json.dumps({"decision": "block", "reason": reason}))


def _cooldown_seconds(used_pct):
    if used_pct >= MAX_CONTEXT_PCT:
        return NUDGE_COOLDOWN_MIN_SEC
    frac = (used_pct - LOW_WATERMARK_PCT) / (MAX_CONTEXT_PCT - LOW_WATERMARK_PCT)
    return NUDGE_COOLDOWN_MAX_SEC - frac * (NUDGE_COOLDOWN_MAX_SEC - NUDGE_COOLDOWN_MIN_SEC)


def _last_assistant_stop_reason(transcript_path):
    """The stop_reason of the most recent assistant turn in the transcript,
    or "unknown" if it can't be determined. A null stop_reason means the turn
    was cancelled or interrupted rather than a genuine stop, so callers
    should not treat that the same as a real stop."""
    try:
        with open(transcript_path) as f:
            lines = f.readlines()
    except OSError:
        return "unknown"

    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") == "assistant":
            return entry.get("message", {}).get("stop_reason", "unknown")
    return "unknown"


def main_stop():
    hook_input = json.load(sys.stdin)
    wapty_id = os.environ.get("WAPTY_ID")
    if not wapty_id:
        return

    transcript_path = hook_input.get("transcript_path")
    if transcript_path and _last_assistant_stop_reason(transcript_path) is None:
        return  # cancelled/interrupted turn, not a genuine stop -- don't nudge

    # Always update state (this consumes need_user / advances stop_count),
    # even on a chained stop we won't block -- otherwise a need_user() call
    # made during a forced continuation never gets consumed, and silently
    # suppresses the nudge on some unrelated future stop instead.
    try:
        result = asyncio.run(call(wapty_id, "on_stop"))
    except Exception:
        return

    if result.get("nudge") and not hook_input.get("stop_hook_active"):
        used_pct = None
        try:
            stats = asyncio.run(call(wapty_id, "get_stats"))
            used_pct = stats.get("context_window", {}).get("used_percentage")
        except Exception:
            pass  # still block below with the base message -- the compact
            # suggestion is a bonus, not a reason to skip the nudge

        _block(
            _render(
                "stop_nudge.txt.j2",
                count=result["count"],
                can_compact=used_pct is not None and used_pct >= MIN_COMPACT_PCT,
                used_pct=used_pct,
            )
        )


def main_posttooluse():
    json.load(sys.stdin)
    wapty_id = os.environ.get("WAPTY_ID")
    if not wapty_id:
        return

    try:
        stats = asyncio.run(call(wapty_id, "get_stats"))
    except Exception:
        return

    used_pct = stats.get("context_window", {}).get("used_percentage")
    if used_pct is None or used_pct < LOW_WATERMARK_PCT:
        return

    if used_pct < MAX_CONTEXT_PCT:
        probability = (used_pct - LOW_WATERMARK_PCT) / (MAX_CONTEXT_PCT - LOW_WATERMARK_PCT)
        if random.random() > probability:
            return
    # at/above MAX_CONTEXT_PCT: nudge unconditionally, subject to cooldown below

    try:
        allowed = asyncio.run(
            call(
                wapty_id,
                "check_cooldown",
                {"name": "posttooluse_nudge", "seconds": _cooldown_seconds(used_pct)},
            )
        )
    except Exception:
        return
    if not allowed:
        return

    _emit(
        _render(
            "posttooluse_nudge.txt.j2",
            used_pct=used_pct,
            low_watermark_pct=LOW_WATERMARK_PCT,
            max_context_pct=MAX_CONTEXT_PCT,
        )
    )
