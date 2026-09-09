"""Where a traceback goes.

stderr is the real terminal once the child is running, so the only correct
destination is the log file beside the control socket. These tests pin both
halves: what reaches the file, and that nothing reaches stderr.
"""

import pytest

import wrapty


@pytest.fixture
def log(tmp_path, monkeypatch):
    path = tmp_path / "session.log"
    monkeypatch.setattr(wrapty, "_log_path", str(path))
    return path


def test_a_logged_exception_carries_its_context_and_traceback(log, capsys):
    try:
        raise RuntimeError("boom inside a connection")
    except RuntimeError:
        wrapty._log_exception("control socket connection")

    written = log.read_text()
    assert "control socket connection" in written
    assert "RuntimeError: boom inside a connection" in written
    assert "Traceback (most recent call last)" in written
    assert capsys.readouterr().err == ""


def test_a_loop_exception_carries_its_message_and_exception(log, capsys):
    wrapty._on_loop_exception(
        None,
        {"message": "Task exception was never retrieved", "exception": ValueError("bad")},
    )

    written = log.read_text()
    assert "Task exception was never retrieved" in written
    assert "ValueError: bad" in written
    assert capsys.readouterr().err == ""


def test_a_loop_exception_without_an_exception_object_still_logs(log):
    wrapty._on_loop_exception(None, {"message": "socket.accept() out of system fds"})
    assert "socket.accept() out of system fds" in log.read_text()


def test_entries_accumulate_rather_than_overwrite(log):
    wrapty._on_loop_exception(None, {"message": "first"})
    wrapty._on_loop_exception(None, {"message": "second"})
    written = log.read_text()
    assert "first" in written and "second" in written


def test_an_unwritable_log_never_raises(tmp_path, monkeypatch):
    """A lost diagnostic must not take the session down with it."""
    monkeypatch.setattr(wrapty, "_log_path", str(tmp_path / "nope" / "session.log"))
    wrapty._on_loop_exception(None, {"message": "still fine"})


def test_before_the_child_starts_diagnostics_go_to_stderr(monkeypatch, capsys):
    """_run() sets the path. Until it does there is no child and no TUI, so
    stderr is still the right place for an error."""
    monkeypatch.setattr(wrapty, "_log_path", None)
    wrapty._write_log("early failure\n")
    assert capsys.readouterr().err == "early failure\n"
