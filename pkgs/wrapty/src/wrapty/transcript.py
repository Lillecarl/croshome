"""What a Claude Code session is still waiting on, read out of its transcript.

The Stop hook gets a transcript path, and the transcript records every
background task the session started and every notification it got back. That
is enough to answer the one question the nudge needs: is there work already
running, or is the session idle with nothing coming?

Three kinds of task appear, and each one opens with its own id:

    command   Bash with run_in_background     toolUseResult.backgroundTaskId
    monitor   the Monitor tool                toolUseResult.taskId
    agent     the Agent tool, async           toolUseResult.agentId

All three close the same way: a `<task-notification>` naming the id with a
terminal `<status>` (completed, failed or killed), or a TaskStop call on it.

A monitor is the reason the deadline field exists. It reports every event but
never reports that it ended, so nothing in the transcript closes one that
expires -- and a task that never closes would silence the stop nudge for the
rest of the session. Its result carries timeoutMs, which bounds it. The other
two kinds get a default bound for the same reason: a transcript resumed with
--resume still lists tasks whose processes died with the previous session.

Reading the whole file on every call is deliberate. Transcripts reach single
digit megabytes, the substring pre-filter throws most lines away before
json.loads sees them, and a stop happens once a turn. State kept between calls
would have to survive a --resume and a compaction; a re-read cannot go stale.
"""

import calendar
import json
import os
import time

# Added to every deadline. A task that has just passed its own timeout may
# still be writing its completion notification.
GRACE_SEC = float(os.environ.get("WRAPTY_TASK_GRACE_SEC", "60"))

# The bound for a task that carries no timeout of its own: a background
# command started without one, and any agent. Deliberately generous -- a
# wrong guess here only decides whether the session gets nudged or poked, and
# both of those recover. Silence would not.
DEFAULT_BOUND_SEC = float(os.environ.get("WRAPTY_TASK_DEFAULT_BOUND_SEC", "3600"))

_TERMINAL_STATUSES = ("completed", "failed", "killed")

# A line has to hold one of these to be worth parsing. They are spelled
# without spaces on purpose: the transcript is compact JSON, but these are
# bare tokens either way, so the filter does not depend on that.
_INTERESTING = (
    "backgroundTaskId",
    "taskId",
    "agentId",
    "task-notification",
    "TaskStop",
    "run_in_background",
    "Monitor",
)


def _epoch(text):
    """Seconds since the epoch for a transcript timestamp, or None.

    Transcript timestamps are UTC ISO with a Z and milliseconds
    (2026-09-03T13:48:21.207Z). datetime.fromisoformat only learned to read
    that Z in 3.11, and this package supports 3.9.
    """
    if not isinstance(text, str) or len(text) < 19:
        return None
    try:
        return calendar.timegm(time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None


def _tag(text, name):
    open_tag = "<%s>" % name
    close_tag = "</%s>" % name
    start = text.find(open_tag)
    if start < 0:
        return None
    end = text.find(close_tag, start)
    if end < 0:
        return None
    return text[start + len(open_tag) : end]


def _blocks(entry):
    message = entry.get("message")
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    return content if isinstance(content, list) else []


def _bound_sec(kind, tool_input):
    if kind == "command":
        timeout_ms = tool_input.get("timeout")
        if isinstance(timeout_ms, (int, float)) and timeout_ms > 0:
            return timeout_ms / 1000.0
    return DEFAULT_BOUND_SEC


def open_tasks(path, now=None):
    """The tasks this session started and has not heard the end of.

    Each is a dict of id, kind, description and deadline. Order is the order
    they started in. A task past its deadline is left out: see the module
    docstring for why a task has one at all.
    """
    now = time.time() if now is None else now
    try:
        with open(path, "r", errors="replace") as handle:
            lines = handle.readlines()
    except OSError:
        return []

    uses = {}  # tool_use id -> (name, input)
    tasks = {}  # task id -> record

    for line in lines:
        if not any(token in line for token in _INTERESTING):
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue

        started = _epoch(entry.get("timestamp")) or now

        for block in _blocks(entry):
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            tool_input = block.get("input")
            uses[block.get("id")] = (
                block.get("name"),
                tool_input if isinstance(tool_input, dict) else {},
            )
            # A TaskStop is the one call whose *request* closes a task; every
            # other close arrives as a notification.
            if block.get("name") == "TaskStop" and isinstance(tool_input, dict):
                tasks.pop(tool_input.get("task_id"), None)
                tasks.pop(tool_input.get("shell_id"), None)

        result = entry.get("toolUseResult")
        if isinstance(result, dict):
            task_id = None
            kind = None
            bound = None
            if result.get("backgroundTaskId"):
                task_id, kind = result["backgroundTaskId"], "command"
            elif result.get("taskId"):
                task_id, kind = result["taskId"], "monitor"
                timeout_ms = result.get("timeoutMs")
                if isinstance(timeout_ms, (int, float)) and timeout_ms > 0:
                    bound = timeout_ms / 1000.0
            elif result.get("agentId") and result.get("isAsync"):
                task_id, kind = result["agentId"], "agent"

            if task_id:
                name, tool_input = "", {}
                for block in _blocks(entry):
                    if isinstance(block, dict) and block.get("tool_use_id") in uses:
                        name, tool_input = uses[block["tool_use_id"]]
                        break
                if bound is None:
                    bound = _bound_sec(kind, tool_input)
                tasks[task_id] = {
                    "id": task_id,
                    "kind": kind,
                    "description": result.get("description")
                    or tool_input.get("description")
                    or name
                    or kind,
                    "deadline": started + bound + GRACE_SEC,
                }

        # A notification is enqueued and later removed, so the same close is
        # seen twice. Dropping an id that is already gone is a no-op.
        content = entry.get("content")
        if isinstance(content, str) and "<task-notification>" in content:
            if _tag(content, "status") in _TERMINAL_STATUSES:
                tasks.pop(_tag(content, "task-id"), None)

    return [task for task in tasks.values() if task["deadline"] > now]


def describe(tasks):
    """One line naming what the session waits on, for a prompt or a log."""
    if not tasks:
        return "nothing"
    return ", ".join('%s "%s"' % (task["kind"], task["description"]) for task in tasks)
