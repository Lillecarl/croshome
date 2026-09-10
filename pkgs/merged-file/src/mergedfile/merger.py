"""Deep-merge declarative settings into an existing config file.

Mappings recurse; every other value (including lists) from the settings
replaces what is on disk. Keys the settings never name are left alone, so
the file stays hand-editable around the merged keys.
"""

from __future__ import annotations

import json
import os
import tomllib

import yaml

try:
    import tomli_w
except ImportError:  # pragma: no cover - nix always provides it
    tomli_w = None  # type: ignore[assignment]


class MergeError(Exception):
    """The file cannot be merged and must fail loudly rather than guess."""


def parse(text: str, format: str) -> dict:
    if not text.strip():
        return {}
    try:
        if format == "json":
            data = json.loads(text)
        elif format == "toml":
            data = tomllib.loads(text)
        elif format == "yaml":
            data = yaml.safe_load(text)
        else:  # pragma: no cover - argparse restricts this before we arrive
            raise MergeError(f"unsupported format: {format}")
    except (json.JSONDecodeError, tomllib.TOMLDecodeError, yaml.YAMLError) as e:
        raise MergeError(f"cannot parse as {format}: {e}") from e
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise MergeError(
            f"top-level {format} value is a {type(data).__name__}, "
            "not a mapping: refusing to merge"
        )
    return data


def serialize(data: dict, format: str) -> str:
    if format == "json":
        return json.dumps(data, indent=2) + "\n"
    if format == "toml":
        if tomli_w is None:  # pragma: no cover - nix always provides it
            raise MergeError("toml writing needs tomli-w")
        try:
            return tomli_w.dumps(data)
        except (TypeError, ValueError) as e:
            raise MergeError(f"cannot write as toml: {e}") from e
    if format == "yaml":
        return yaml.safe_dump(data, sort_keys=False)
    raise MergeError(f"unsupported format: {format}")  # pragma: no cover


def deep_merge(base: dict, overlay: dict) -> dict:
    merged = dict(base)
    for key, value in overlay.items():
        if key in merged and isinstance(merged[key], dict) and isinstance(value, dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def merge_file(path: str, format: str, settings: dict, create: bool = True) -> str:
    """Merge settings into path. Returns created, updated, up-to-date or skipped."""
    try:
        with open(path, encoding="utf-8") as f:
            original_text = f.read()
    except FileNotFoundError:
        if not create:
            return "skipped"
        current: dict = {}
        original_text = None
    else:
        current = parse(original_text, format)

    merged = deep_merge(current, settings)
    if original_text is not None and merged == current:
        return "up-to-date"

    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(serialize(merged, format))
    os.replace(tmp_path, path)
    return "created" if original_text is None else "updated"
