"""secrets/sops/keys.json and the .sops.yaml made from it. Pure: no IO here."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field, replace
from typing import Final

MASTER: Final = "master"


@dataclass(frozen=True, slots=True)
class Keys:
    """Who can decrypt which file.

    `admins` open every file. `hosts` each open `hosts/<name>.yaml`, plus the
    shared files that `files` lists them under.
    """

    admins: dict[str, str]
    hosts: dict[str, str]
    files: dict[str, list[str]] = field(default_factory=dict)

    @classmethod
    def parse(cls, text: str) -> Keys:
        raw = json.loads(text)
        return cls(admins=raw["admins"], hosts=raw["hosts"], files=raw.get("files", {}))

    def dump(self) -> str:
        body = {"admins": self.admins, "hosts": self.hosts, "files": self.files}
        return json.dumps(body, indent=2, sort_keys=True) + "\n"


def readers(keys: Keys) -> dict[str, list[str]]:
    """Each sops file, relative to secrets/sops, to the hosts that read it."""
    own = {f"hosts/{name}.yaml": [name] for name in keys.hosts}
    return own | keys.files


def sops_config(keys: Keys) -> dict[str, list[dict[str, object]]]:
    """The .sops.yaml document. `object`: sops's own schema, mixed value types."""
    rules: list[dict[str, object]] = []
    for path, hosts in sorted(readers(keys).items()):
        unknown = [h for h in hosts if h not in keys.hosts]
        if unknown:
            raise ValueError(f"{path} names unknown hosts: {', '.join(unknown)}")
        recipients = list(keys.admins.values()) + [keys.hosts[h] for h in hosts]
        rules.append(
            {
                "path_regex": f"(^|/){re.escape(path)}$",
                "key_groups": [{"age": recipients}],
            }
        )
    return {"creation_rules": rules}


def with_host(keys: Keys, name: str, recipient: str, files: list[str]) -> Keys:
    shared = dict(keys.files)
    for path in files:
        shared[path] = sorted({*shared.get(path, []), name})
    return replace(keys, hosts=keys.hosts | {name: recipient}, files=shared)


def without_host(keys: Keys, name: str) -> Keys:
    hosts = {k: v for k, v in keys.hosts.items() if k != name}
    shared = {path: [h for h in hs if h != name] for path, hs in keys.files.items()}
    return replace(keys, hosts=hosts, files=shared)


def with_admin(keys: Keys, name: str, recipient: str) -> Keys:
    return replace(keys, admins=keys.admins | {name: recipient})


def without_admin(keys: Keys, name: str) -> Keys:
    if name == MASTER:
        raise ValueError("the master key stays an admin")
    return replace(keys, admins={k: v for k, v in keys.admins.items() if k != name})


def key_path(dotted: str) -> list[str]:
    """`aid.token` -> ["aid", "token"]."""
    parts = dotted.split(".")
    if not all(parts):
        raise ValueError(f"empty component in key {dotted!r}")
    return parts


def sops_index(dotted: str) -> str:
    """`aid.token` -> `["aid"]["token"]`, the form `sops --extract` and `set` take."""
    return "".join(f"[{json.dumps(p)}]" for p in key_path(dotted))


def nested(dotted: str, value: str) -> dict[str, object]:
    """`a.b`, v -> {"a": {"b": v}}. `object`: nesting depth is data."""
    *outer, last = key_path(dotted)
    out: dict[str, object] = {last: value}
    for part in reversed(outer):
        out = {part: out}
    return out
