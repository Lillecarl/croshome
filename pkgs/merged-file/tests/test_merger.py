import json
import os

import pytest

from mergedfile.cli import main
from mergedfile.merger import MergeError
from mergedfile.merger import deep_merge
from mergedfile.merger import merge_file


def write(path, text):
    path.write_text(text, encoding="utf-8")
    return str(path)


def test_json_merge_preserves_unmentioned_keys(tmp_path):
    target = write(
        tmp_path / "config.json",
        json.dumps({"keep": 1, "nested": {"a": 1, "b": 2}, "list": [1, 2]}),
    )
    assert merge_file(target, "json", {"nested": {"b": 3}, "list": [9]}) == "updated"
    assert json.loads(open(target, encoding="utf-8").read()) == {
        "keep": 1,
        "nested": {"a": 1, "b": 3},
        "list": [9],
    }


def test_json_exact_rendering(tmp_path):
    target = write(tmp_path / "config.json", "{}")
    merge_file(target, "json", {"b": 2, "a": 1})
    assert open(target, encoding="utf-8").read() == '{\n  "b": 2,\n  "a": 1\n}\n'


def test_noop_leaves_file_untouched(tmp_path):
    target = write(tmp_path / "config.json", '{\n  "a": 1\n}\n')
    before = os.stat(target).st_mtime_ns
    assert merge_file(target, "json", {"a": 1}) == "up-to-date"
    assert os.stat(target).st_mtime_ns == before
    assert open(target, encoding="utf-8").read() == '{\n  "a": 1\n}\n'


def test_missing_file_create_and_no_create(tmp_path):
    target = str(tmp_path / "sub" / "config.json")
    assert merge_file(target, "json", {"a": 1}, create=False) == "skipped"
    assert not os.path.exists(target)
    assert merge_file(target, "json", {"a": 1}, create=True) == "created"
    assert json.loads(open(target, encoding="utf-8").read()) == {"a": 1}


def test_empty_file_counts_as_empty_mapping(tmp_path):
    target = write(tmp_path / "config.json", "\n")
    assert merge_file(target, "json", {"a": 1}) == "updated"
    assert json.loads(open(target, encoding="utf-8").read()) == {"a": 1}


def test_corrupt_file_fails_loudly(tmp_path):
    target = write(tmp_path / "config.json", '{"a": ')
    with pytest.raises(MergeError):
        merge_file(target, "json", {"a": 1})
    assert open(target, encoding="utf-8").read() == '{"a": '


def test_non_mapping_top_level_refuses(tmp_path):
    target = write(tmp_path / "config.json", "[1, 2]")
    with pytest.raises(MergeError):
        merge_file(target, "json", {"a": 1})


def test_deep_merge_replaces_lists_and_scalars():
    assert deep_merge({"a": {"x": 1}, "l": [1]}, {"a": {"y": 2}, "l": [2]}) == {
        "a": {"x": 1, "y": 2},
        "l": [2],
    }


def test_toml_round_trip(tmp_path):
    target = write(tmp_path / "config.toml", 'title = "old"\n[server]\nhost = "a"\n')
    assert merge_file(target, "toml", {"server": {"port": 8080}}) == "updated"
    import tomllib

    assert tomllib.loads(open(target, encoding="utf-8").read()) == {
        "title": "old",
        "server": {"host": "a", "port": 8080},
    }


def test_yaml_round_trip_preserves_order(tmp_path):
    target = write(tmp_path / "config.yaml", "zebra: 1\napple: 2\n")
    assert merge_file(target, "yaml", {"mango": 3}) == "updated"
    assert open(target, encoding="utf-8").read() == "zebra: 1\napple: 2\nmango: 3\n"


def test_cli_end_to_end(tmp_path, capsys):
    target = write(tmp_path / "config.json", '{"keep": true}')
    settings = write(tmp_path / "settings.json", '{"added": [1]}')
    assert main(["--path", target, "--format", "json", "--settings", settings]) == 0
    assert "updated" in capsys.readouterr().out
    assert json.loads(open(target, encoding="utf-8").read()) == {
        "keep": True,
        "added": [1],
    }


def test_cli_missing_with_no_create(tmp_path, capsys):
    target = str(tmp_path / "absent.json")
    settings = write(tmp_path / "settings.json", "{}")
    assert (
        main(["--path", target, "--format", "json", "--settings", settings, "--no-create"])
        == 0
    )
    assert "skipped" in capsys.readouterr().out


def test_cli_corrupt_file_exits_nonzero(tmp_path, capsys):
    target = write(tmp_path / "config.json", "not yaml: [")
    settings = write(tmp_path / "settings.json", "{}")
    assert main(["--path", target, "--format", "yaml", "--settings", settings]) == 1
    assert capsys.readouterr().err != ""
