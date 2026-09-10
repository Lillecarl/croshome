"""Command-line entry point: merge a Nix-generated settings file into a config file."""

from __future__ import annotations

import argparse
import json
import os
import sys

from .merger import MergeError
from .merger import merge_file


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="merged-file",
        description="Deep-merge declarative settings into an existing config file.",
    )
    parser.add_argument("--path", required=True, help="Config file to merge into.")
    parser.add_argument(
        "--format", required=True, choices=("json", "toml", "yaml"), help="File format."
    )
    parser.add_argument(
        "--settings", required=True, help="JSON file holding the settings to merge."
    )
    parser.add_argument(
        "--no-create",
        action="store_true",
        help="Leave a missing file alone instead of creating it.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    try:
        with open(args.settings, encoding="utf-8") as f:
            settings = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"merged-file: settings {args.settings}: {e}", file=sys.stderr)
        return 1
    if not isinstance(settings, dict):
        print("merged-file: settings must be a JSON object", file=sys.stderr)
        return 1

    path = os.path.expanduser(args.path)
    try:
        result = merge_file(path, args.format, settings, create=not args.no_create)
    except MergeError as e:
        print(f"merged-file: {path}: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"merged-file: {path}: {e.strerror or e}", file=sys.stderr)
        return 1
    print(f"merged-file: {path}: {result}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
