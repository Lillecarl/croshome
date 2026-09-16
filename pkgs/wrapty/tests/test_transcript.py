"""open_tasks reads a session's outstanding background work from its transcript.

The shapes asserted here are not invented: every one is copied from a real
Claude Code transcript under ~/.claude/projects. If a future Claude Code
changes them, these tests are where it shows.
"""

import json
import time

import pytest

from wrapty import transcript

BASE = 1_756_900_000  # a fixed epoch, so a deadline test cannot flake


def stamp(offset=0):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(BASE + offset))


def tool_use(use_id, name, tool_input, offset=0):
    return {
        "type": "assistant",
        "timestamp": stamp(offset),
        "message": {
            "role": "assistant",
            "content": [
                {"type": "tool_use", "id": use_id, "name": name, "input": tool_input}
            ],
        },
    }


def tool_result(use_id, result, offset=0):
    return {
        "type": "user",
        "timestamp": stamp(offset),
        "message": {
            "role": "user",
            "content": [{"type": "tool_result", "tool_use_id": use_id, "content": "ok"}],
        },
        "toolUseResult": result,
    }


def notification(task_id, status, offset=0, operation="enqueue"):
    body = "<task-notification>\n<task-id>%s</task-id>\n<status>%s</status>\n" % (
        task_id,
        status,
    )
    return {
        "type": "queue-operation",
        "operation": operation,
        "timestamp": stamp(offset),
        "content": body + "</task-notification>",
    }


def monitor_event(task_id, offset=0):
    """A monitor reports events with no status at all -- only its expiry or a
    TaskStop ends it, and neither is written to the transcript."""
    return {
        "type": "queue-operation",
        "operation": "enqueue",
        "timestamp": stamp(offset),
        "content": (
            "<task-notification>\n<task-id>%s</task-id>\n"
            "<summary>Monitor event: \"tailing\"</summary>\n</task-notification>"
        )
        % task_id,
    }


def write(tmp_path, entries):
    path = tmp_path / "transcript.jsonl"
    path.write_text("".join(json.dumps(entry) + "\n" for entry in entries))
    return str(path)


def background_command(tmp_path, task_id="bxxxx", timeout=None, offset=0):
    tool_input = {"command": "until [ -f flag ]; do sleep 5; done",
                  "description": "wait for the flag",
                  "run_in_background": True}
    if timeout is not None:
        tool_input["timeout"] = timeout
    return [
        tool_use("toolu_1", "Bash", tool_input, offset),
        tool_result("toolu_1", {"backgroundTaskId": task_id}, offset),
    ]


def test_a_background_command_is_open_until_it_reports(tmp_path):
    path = write(tmp_path, background_command(tmp_path))
    assert [task["id"] for task in transcript.open_tasks(path, now=BASE + 10)] == ["bxxxx"]


def test_the_description_comes_from_the_call_that_started_it(tmp_path):
    path = write(tmp_path, background_command(tmp_path))
    task = transcript.open_tasks(path, now=BASE + 10)[0]
    assert task["description"] == "wait for the flag"
    assert task["kind"] == "command"


@pytest.mark.parametrize("status", ["completed", "failed", "killed"])
def test_a_terminal_notification_closes_it(tmp_path, status):
    entries = background_command(tmp_path) + [notification("bxxxx", status, 5)]
    assert transcript.open_tasks(write(tmp_path, entries), now=BASE + 10) == []


def test_the_same_notification_twice_is_still_closed(tmp_path):
    """Claude Code enqueues a notification and removes it again, so the
    transcript holds two copies of every close."""
    entries = background_command(tmp_path) + [
        notification("bxxxx", "completed", 5, "enqueue"),
        notification("bxxxx", "completed", 6, "remove"),
    ]
    assert transcript.open_tasks(write(tmp_path, entries), now=BASE + 10) == []


def test_an_event_without_a_status_leaves_it_open(tmp_path):
    entries = background_command(tmp_path) + [monitor_event("bxxxx", 5)]
    assert len(transcript.open_tasks(write(tmp_path, entries), now=BASE + 10)) == 1


def test_a_command_with_its_own_timeout_expires_at_that_timeout(tmp_path):
    path = write(tmp_path, background_command(tmp_path, timeout=600_000))
    assert len(transcript.open_tasks(path, now=BASE + 600)) == 1
    assert transcript.open_tasks(path, now=BASE + 600 + transcript.GRACE_SEC + 1) == []


def test_a_command_without_one_gets_the_default_bound(tmp_path):
    path = write(tmp_path, background_command(tmp_path))
    edge = BASE + transcript.DEFAULT_BOUND_SEC + transcript.GRACE_SEC
    assert len(transcript.open_tasks(path, now=edge - 1)) == 1
    assert transcript.open_tasks(path, now=edge + 1) == []


def test_a_monitor_expires_at_its_own_timeout(tmp_path):
    """The reason deadlines exist: nothing in the transcript ever closes a
    monitor, so without one it would silence the nudge forever."""
    entries = [
        tool_use("toolu_2", "Monitor", {"description": "kubeadm progress"}),
        tool_result("toolu_2", {"taskId": "bk7jt8j2h", "timeoutMs": 900_000}),
    ]
    path = write(tmp_path, entries)
    task = transcript.open_tasks(path, now=BASE + 10)[0]
    assert (task["kind"], task["description"]) == ("monitor", "kubeadm progress")
    assert transcript.open_tasks(path, now=BASE + 900 + transcript.GRACE_SEC + 1) == []


def test_task_stop_closes_a_monitor_before_its_timeout(tmp_path):
    entries = [
        tool_use("toolu_2", "Monitor", {"description": "kubeadm progress"}),
        tool_result("toolu_2", {"taskId": "bk7jt8j2h", "timeoutMs": 900_000}),
        tool_use("toolu_3", "TaskStop", {"task_id": "bk7jt8j2h"}, 30),
    ]
    assert transcript.open_tasks(write(tmp_path, entries), now=BASE + 60) == []


def test_an_async_agent_is_a_task_too(tmp_path):
    entries = [
        tool_use("toolu_4", "Agent", {"description": "survey the repo"}),
        tool_result(
            "toolu_4",
            {
                "isAsync": True,
                "status": "async_launched",
                "agentId": "a9fa99703d69cd599",
                "description": "survey the repo",
            },
        ),
    ]
    path = write(tmp_path, entries)
    assert transcript.open_tasks(path, now=BASE + 10)[0]["kind"] == "agent"
    closed = entries + [notification("a9fa99703d69cd599", "completed", 20)]
    assert transcript.open_tasks(write(tmp_path, closed), now=BASE + 30) == []


def test_a_transcript_that_is_not_there_is_not_an_error(tmp_path):
    """The hook hands over whatever path it was given. A session with no
    transcript yet must read as 'nothing outstanding', not blow up the hook."""
    assert transcript.open_tasks(str(tmp_path / "nope.jsonl")) == []


def test_a_broken_line_does_not_stop_the_parse(tmp_path):
    path = tmp_path / "transcript.jsonl"
    entries = background_command(tmp_path)
    path.write_text(
        "{truncated, backgroundTaskId\n" + "".join(json.dumps(e) + "\n" for e in entries)
    )
    assert len(transcript.open_tasks(str(path), now=BASE + 10)) == 1


def test_describe_names_the_kind_and_the_description(tmp_path):
    path = write(tmp_path, background_command(tmp_path))
    assert transcript.describe(transcript.open_tasks(path, now=BASE + 10)) == (
        'command "wait for the flag"'
    )
    assert transcript.describe([]) == "nothing"
