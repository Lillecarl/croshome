"""Transcript fixtures shared by the tests that need a session to be waiting
on something. The shapes are copied from real Claude Code transcripts; see
wrapty/transcript.py for what each field means."""

import json
import time

TASK_DESCRIPTION = "wait for the flag"


def transcript_with_one_open_task(path, task_id="bwatch1"):
    """A transcript holding a background command that never reported."""
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    entries = [
        {
            "type": "assistant",
            "timestamp": stamp,
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "Bash",
                        "input": {
                            "command": "until [ -f flag ]; do sleep 5; done",
                            "description": TASK_DESCRIPTION,
                            "run_in_background": True,
                        },
                    }
                ],
            },
        },
        {
            "type": "user",
            "timestamp": stamp,
            "message": {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"}
                ],
            },
            "toolUseResult": {"backgroundTaskId": task_id},
        },
    ]
    with open(path, "w") as handle:
        for entry in entries:
            handle.write(json.dumps(entry) + "\n")
