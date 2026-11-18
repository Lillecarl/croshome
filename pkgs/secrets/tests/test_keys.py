from __future__ import annotations

import re

import pytest
from croshome_secrets import keys as k

KEYS = k.Keys(
    admins={"master": "age1master"},
    hosts={"a": "age1a", "b": "age1b"},
    files={"user.yaml": ["a", "b"], "admin.yaml": []},
)


def rule_for(
    config: dict[str, list[dict[str, object]]], path: str
) -> dict[str, object]:
    (rule,) = [
        r for r in config["creation_rules"] if re.search(str(r["path_regex"]), path)
    ]
    return rule


def test_host_file_goes_to_admins_and_that_host() -> None:
    rule = rule_for(k.sops_config(KEYS), "hosts/a.yaml")
    assert rule["key_groups"] == [{"age": ["age1master", "age1a"]}]


def test_regex_is_anchored_and_dot_literal() -> None:
    config = k.sops_config(KEYS)
    assert rule_for(config, "./user.yaml")["path_regex"] == r"(^|/)user\.yaml$"
    assert not [
        r
        for r in config["creation_rules"]
        if re.search(str(r["path_regex"]), "userXyaml")
    ]


def test_admin_only_file() -> None:
    assert rule_for(k.sops_config(KEYS), "admin.yaml")["key_groups"] == [
        {"age": ["age1master"]}
    ]


def test_unknown_host_in_files_is_an_error() -> None:
    bad = k.Keys(admins=KEYS.admins, hosts=KEYS.hosts, files={"x.yaml": ["nope"]})
    with pytest.raises(ValueError, match="nope"):
        k.sops_config(bad)


def test_with_host_adds_to_files_once() -> None:
    added = k.with_host(KEYS, "c", "age1c", ["user.yaml", "user.yaml", "new.yaml"])
    assert added.hosts["c"] == "age1c"
    assert added.files["user.yaml"] == ["a", "b", "c"]
    assert added.files["new.yaml"] == ["c"]
    assert KEYS.files["user.yaml"] == ["a", "b"]


def test_without_host_clears_files() -> None:
    gone = k.without_host(KEYS, "a")
    assert "a" not in gone.hosts
    assert gone.files["user.yaml"] == ["b"]


def test_master_cannot_be_removed() -> None:
    with pytest.raises(ValueError):
        k.without_admin(KEYS, "master")


def test_round_trip() -> None:
    assert k.Keys.parse(KEYS.dump()) == KEYS


def test_index_and_nested() -> None:
    assert k.sops_index("aid.token") == '["aid"]["token"]'
    assert k.nested("host-keys.x.private", "v") == {
        "host-keys": {"x": {"private": "v"}}
    }
    with pytest.raises(ValueError):
        k.key_path("a..b")
