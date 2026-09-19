"""The Stop hook only nudges a session somebody is watching.

Two separate failures hide behind one check. The nudge cannot be cleared
with no human there, so it would block every headless run's last stop. And
WAPTY_ID is inherited, so an unattended session started from inside a
wrapped one reaches its parent's control socket -- calling on_stop there
would spend the parent's need_user and advance its stop_count. So the test
that matters is not "no nudge printed", it is "the socket was never called
at all".
"""

import io
import json

from wrapty import hooks


def _run_stop(monkeypatch, env, calls):
    for name in ("WAPTY_ID", "CLAUDE_CODE_SESSION_ATTENDED"):
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)

    def record(*args, **kwargs):
        calls.append((args, kwargs))
        raise AssertionError("the control socket must not be reached")

    monkeypatch.setattr(hooks, "call", record)
    monkeypatch.setattr(hooks.sys, "stdin", io.StringIO(json.dumps({})))
    hooks.main_stop()


def test_an_unattended_session_never_reaches_the_socket(monkeypatch, capsys):
    calls = []
    _run_stop(
        monkeypatch,
        {"WAPTY_ID": "abc123", "CLAUDE_CODE_SESSION_ATTENDED": "0"},
        calls,
    )
    assert calls == []
    assert capsys.readouterr().out == ""


def test_an_attended_session_still_calls_on_stop(monkeypatch):
    calls = []
    try:
        _run_stop(
            monkeypatch,
            {"WAPTY_ID": "abc123", "CLAUDE_CODE_SESSION_ATTENDED": "1"},
            calls,
        )
    except AssertionError:
        pass  # the stub raises on purpose; reaching it is the assertion
    assert calls, "an attended session must still update the nudge state"


def test_an_absent_variable_counts_as_attended(monkeypatch):
    """A Claude Code too old to set it only ever ran interactive sessions."""
    calls = []
    try:
        _run_stop(monkeypatch, {"WAPTY_ID": "abc123"}, calls)
    except AssertionError:
        pass
    assert calls, "an unset variable must not silence the nudge"


def test_no_wapty_id_short_circuits_before_the_attended_check(monkeypatch):
    calls = []
    _run_stop(monkeypatch, {"CLAUDE_CODE_SESSION_ATTENDED": "1"}, calls)
    assert calls == []
