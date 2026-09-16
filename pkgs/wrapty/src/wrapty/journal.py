"""An append-only record of the moments worth studying after the session.

One JSON object per line, at $XDG_STATE_HOME/wrapty/journal.jsonl. It exists
because a rule about when to stop can only be tuned against real stops: the
nudge tells an agent that only two things earn a turn ending, and the way to
find out whether it believes that is to read what it wrote down each time it
ended one.

So a need_user record carries the state around the call, not only the reason.
The rows worth reading are the ones where the agent stopped with work still
running, or stopped straight after being nudged back:

    jq 'select(.nudged or (.waiting | length > 0))' \\
        ~/.local/state/wrapty/journal.jsonl

Nothing here is load-bearing. A record that cannot be written is lost and the
session carries on: journalling is how the rules get better later, never how
the session works now.
"""

import json
import os
import time

from wrapty.client import state_dir

# Long enough for a sentence with its reasoning, short enough that one record
# stays a single small write -- sessions on one machine append to the same
# file, and a short line is one atomic O_APPEND rather than two interleaved.
FIELD_MAX = 500


def path() -> str:
    return os.path.join(state_dir(), "journal.jsonl")


def _clip(value):
    if isinstance(value, str) and len(value) > FIELD_MAX:
        return value[: FIELD_MAX - 1] + "…"
    if isinstance(value, list):
        return [_clip(item) for item in value]
    return value


def append(event, **fields) -> bool:
    """Write one record. True when it landed, False when it did not."""
    record = {"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": event}
    record.update({key: _clip(value) for key, value in fields.items()})
    try:
        os.makedirs(state_dir(), exist_ok=True)
        with open(path(), "a") as handle:
            handle.write(json.dumps(record, default=str) + "\n")
    except OSError:
        return False
    return True
