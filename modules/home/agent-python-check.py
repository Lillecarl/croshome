"""Check scripts written for agent-python with ruff and pyrefly.

Both tools run isolated from any project configuration and resolve imports
against the agent-python venv. stdout carries the findings; a clean run prints
nothing. Exit 0 when clean, 1 when a tool reports findings, 2 on usage errors.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING, Final

import anyio

if TYPE_CHECKING:
    from collections.abc import Sequence

RUFF: Final = "@ruff@"
PYREFLY: Final = "@pyrefly@"
VENV_PYTHON: Final = "@venvPython@"
TARGET_VERSION: Final = "@targetVersion@"

# The default set catches bugs and dated idioms without arguing about style
# the formatter already settles.
DEFAULT_SELECT: Final = (
    "E",
    "F",
    "W",
    "I",
    "UP",
    "B",
    "SIM",
    "ASYNC",
    "RUF",
    "PTH",
    "C4",
    "PERF",
    "TRY",
    "FURB",
    "LOG",
    "PIE",
    "RET",
    "TC",
    "FA",
)
DEFAULT_IGNORE: Final = ("E501", "TRY003")

# Strict is everything ruff has, minus rules that fight the formatter, demand
# docs or packaging a one-off script does not have, or ban print in a script.
STRICT_SELECT: Final = ("ALL",)
STRICT_IGNORE: Final = (
    "D",
    "CPY",
    "COM812",
    "ISC001",
    "E501",
    "T20",
    "INP001",
    "TRY003",
    "EM",
)


class Preset(StrEnum):
    DEFAULT = "default"
    STRICT = "strict"


@dataclass(frozen=True, slots=True)
class Result:
    tool: str
    returncode: int
    output: str


async def run(tool: str, argv: Sequence[str]) -> Result:
    proc = await anyio.run_process(argv, check=False, stderr=sys.stderr.buffer)
    return Result(tool, proc.returncode, proc.stdout.decode())


def ruff_rules(*, strict: bool) -> list[str]:
    select, ignore = (
        (STRICT_SELECT, STRICT_IGNORE) if strict else (DEFAULT_SELECT, DEFAULT_IGNORE)
    )
    return ["--select", ",".join(select), "--ignore", ",".join(ignore)]


def ruff_check(paths: Sequence[str], *, strict: bool, fix: bool) -> list[str]:
    return [
        RUFF,
        "check",
        "--isolated",
        "--quiet",
        "--output-format",
        "concise",
        "--target-version",
        TARGET_VERSION,
        *ruff_rules(strict=strict),
        *(["--fix"] if fix else []),
        "--",
        *paths,
    ]


def ruff_format(paths: Sequence[str], *, fix: bool) -> list[str]:
    mode = [] if fix else ["--check", "--diff"]
    return [
        RUFF,
        "format",
        "--isolated",
        "--quiet",
        "--target-version",
        TARGET_VERSION,
        *mode,
        "--",
        *paths,
    ]


def pyrefly(paths: Sequence[str], *, strict: bool) -> list[str]:
    preset = Preset.STRICT if strict else Preset.DEFAULT
    return [
        PYREFLY,
        "check",
        "--python-interpreter-path",
        VENV_PYTHON,
        "--preset",
        preset,
        "--output-format",
        "min-text",
        "--summary=none",
        "--color",
        "never",
        "--",
        *paths,
    ]


def parse(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="agent-python-check",
        description="Lint, format-check and type-check scripts against the agent-python venv.",
    )
    parser.add_argument("paths", nargs="+", help="files or directories to check")
    parser.add_argument(
        "--fix", action="store_true", help="apply ruff fixes and formatting first"
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="every ruff rule and pyrefly's strict preset",
    )
    parser.add_argument(
        "--no-ruff", dest="ruff", action="store_false", help="skip ruff"
    )
    parser.add_argument(
        "--no-pyrefly", dest="pyrefly", action="store_false", help="skip pyrefly"
    )
    return parser.parse_args(argv)


async def main(argv: Sequence[str]) -> int:
    args = parse(argv)
    results: list[Result] = []

    if args.ruff and args.fix:
        # Fixes rewrite the files the other checks read, so they finish first.
        results.append(
            await run(
                "ruff check --fix", ruff_check(args.paths, strict=args.strict, fix=True)
            )
        )
        results.append(await run("ruff format", ruff_format(args.paths, fix=True)))

    async def collect(tool: str, cmd: list[str]) -> None:
        results.append(await run(tool, cmd))

    async with anyio.create_task_group() as tg:
        if args.ruff and not args.fix:
            tg.start_soon(
                collect,
                "ruff check",
                ruff_check(args.paths, strict=args.strict, fix=False),
            )
            tg.start_soon(collect, "ruff format", ruff_format(args.paths, fix=False))
        if args.pyrefly:
            tg.start_soon(collect, "pyrefly", pyrefly(args.paths, strict=args.strict))

    failed = False
    for result in results:
        if result.output.strip():
            sys.stdout.write(f"== {result.tool}\n{result.output.rstrip()}\n")
        failed |= result.returncode != 0
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(anyio.run(main, sys.argv[1:]))
