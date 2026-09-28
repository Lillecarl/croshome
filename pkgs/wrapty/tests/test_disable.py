"""WRAPTY_DISABLE=1 detaches a process tree from its wrapty session.

WAPTY_ID is inherited. An agent daemon started from inside a wrapped session
passes it to every Claude it runs, and their hooks then reach the parent's
control socket. Measured with aid: a claude-agent-acp session it started
blocked on the parent's Stop nudge, called need_user, and answered twice.
"""

import io
import json

import pytest

from wrapty import client, hooks, wrapper


def _hook_env(monkeypatch, disable):
    monkeypatch.setenv("WAPTY_ID", "abc123")
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ATTENDED", "1")
    if disable is None:
        monkeypatch.delenv(client.DISABLE_ENV, raising=False)
    else:
        monkeypatch.setenv(client.DISABLE_ENV, disable)


@pytest.mark.parametrize("main", [hooks.main_stop, hooks.main_posttooluse])
def test_disabled_hooks_never_reach_the_socket(monkeypatch, capsys, main):
    _hook_env(monkeypatch, "1")
    calls = []
    monkeypatch.setattr(hooks, "call", lambda *a, **k: calls.append(a))
    monkeypatch.setattr(hooks.sys, "stdin", io.StringIO(json.dumps({})))
    main()
    assert calls == []
    assert capsys.readouterr().out == ""


@pytest.mark.parametrize(("disable", "expected"), [(None, "abc123"), ("0", "abc123"), ("1", None)])
def test_session_id(monkeypatch, disable, expected):
    _hook_env(monkeypatch, disable)
    assert client.session_id() == expected


def test_disabled_wrapper_runs_the_command_unwrapped(monkeypatch):
    monkeypatch.setenv(client.DISABLE_ENV, "1")
    monkeypatch.setattr(wrapper.sys, "argv", ["wrapty", "claude", "--resume"])
    execs = []

    def fake_execvp(file, args):
        execs.append((file, args))
        raise SystemExit(0)

    monkeypatch.setattr(wrapper.os, "execvp", fake_execvp)
    with pytest.raises(SystemExit):
        wrapper.main()
    assert execs == [("claude", ["claude", "--resume"])]
