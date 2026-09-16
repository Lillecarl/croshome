"""The journal: one JSON line per recorded moment, and never in the way.

Its whole purpose is to be read long after the session, so the two things
that matter are that a record is valid JSON with the fields somebody will
filter on, and that failing to write one never reaches the session. A stop
that cannot be journalled is still a stop.
"""

import json
import os

import pytest

from wrapty import journal


@pytest.fixture
def state_home(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    return tmp_path


def _records(state_home):
    path = state_home / "wrapty" / "journal.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()]


def test_a_record_lands_as_one_json_line(state_home):
    assert journal.append("need_user", reason="the work is done", nudged=False)
    record = _records(state_home)[0]
    assert record["event"] == "need_user"
    assert record["reason"] == "the work is done"
    assert record["nudged"] is False
    assert record["time"]


def test_records_accumulate_rather_than_replace(state_home):
    journal.append("need_user", reason="one")
    journal.append("need_user", reason="two")
    assert [r["reason"] for r in _records(state_home)] == ["one", "two"]


def test_the_directory_is_made_if_it_is_missing(state_home):
    assert not (state_home / "wrapty").exists()
    journal.append("need_user", reason="x")
    assert (state_home / "wrapty" / "journal.jsonl").exists()


def test_a_long_field_is_clipped_so_one_record_stays_one_write(state_home):
    """Sessions on one machine append to the same file. A short line is a
    single atomic O_APPEND; a huge one can interleave with another."""
    journal.append("need_user", reason="x" * 5000, waiting=["y" * 5000])
    record = _records(state_home)[0]
    assert len(record["reason"]) == journal.FIELD_MAX
    assert len(record["waiting"][0]) == journal.FIELD_MAX


def test_a_journal_that_cannot_be_written_is_not_an_error(tmp_path, monkeypatch):
    """The session must not care. A file where the directory should be is the
    cheapest way to make every write fail."""
    blocked = tmp_path / "state"
    blocked.write_text("not a directory")
    monkeypatch.setenv("XDG_STATE_HOME", str(blocked))
    assert journal.append("need_user", reason="x") is False


def test_a_value_that_is_not_json_still_records(state_home):
    """A record is a diagnostic, not a schema. Something unserializable in
    one field must not lose the whole row."""
    journal.append("need_user", reason="x", odd=object())
    assert _records(state_home)[0]["reason"] == "x"


def test_the_path_follows_xdg_state_home(state_home):
    assert journal.path() == str(state_home / "wrapty" / "journal.jsonl")


def test_it_defaults_under_the_home_directory(monkeypatch):
    monkeypatch.delenv("XDG_STATE_HOME", raising=False)
    assert journal.path().startswith(os.path.expanduser("~/.local/state"))
