"""Switch a service's dev profile to a fresh build, without a system rebuild.

The profiles, how to build each one and which user units run it come from the
JSON that ./devprofiles.nix writes. stdout carries one JSON result; build
output and errors go to stderr. Exit 0 on success, 1 when a step fails, 2 on
usage errors.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Final

import anyio

if TYPE_CHECKING:
    from collections.abc import Sequence

CONFIG: Final = Path("@config@")
NIX: Final = "@nix@"
NIX_ENV: Final = "@nixEnv@"
SYSTEMCTL: Final = "@systemctl@"
JOURNALCTL: Final = "@journalctl@"


@dataclass(frozen=True, slots=True)
class Profile:
    name: str
    path: Path
    file: str
    attr: str
    units: tuple[str, ...]
    pinned: str
    mode: str

    def current(self) -> str | None:
        return str(self.path.resolve()) if self.path.exists() else None


@dataclass(frozen=True, slots=True)
class Outcome:
    name: str
    previous: str | None
    current: str | None
    changed: bool
    units: dict[str, str] = field(default_factory=dict)


class StepError(Exception):
    pass


def load() -> dict[str, Profile]:
    raw = json.loads(CONFIG.read_text())
    return {
        name: Profile(
            name=name,
            path=Path(p["profile"]),
            file=p["file"],
            attr=p["attr"],
            units=tuple(p["units"]),
            pinned=p["pinned"],
            mode=p["mode"],
        )
        for name, p in raw.items()
    }


async def run(argv: Sequence[str], *, capture: bool = False) -> str:
    proc = await anyio.run_process(
        argv,
        check=False,
        stdout=None if not capture else -1,
        stderr=sys.stderr.buffer,
    )
    if proc.returncode != 0:
        raise StepError(f"{argv[0]} exited {proc.returncode}: {' '.join(argv[1:])}")
    return proc.stdout.decode() if capture and proc.stdout else ""


async def build(profile: Profile) -> str:
    out = await run(
        [
            NIX,
            "build",
            "--no-link",
            "--print-out-paths",
            "--file",
            profile.file,
            profile.attr,
        ],
        capture=True,
    )
    paths = out.split()
    if not paths:
        raise StepError(f"nix build printed no path for {profile.attr}")
    return paths[0]


async def switch(profile: Profile, target: str) -> None:
    profile.path.parent.mkdir(parents=True, exist_ok=True)
    await run([NIX_ENV, "--profile", str(profile.path), "--set", target])


async def load_state(unit: str) -> str:
    proc = await anyio.run_process(
        [SYSTEMCTL, "--user", "show", "--property", "LoadState", "--value", unit],
        check=False,
    )
    return proc.stdout.decode().strip()


async def restart(profile: Profile) -> dict[str, str]:
    """`try-restart`: a unit that is stopped stays stopped.

    A listed unit the user manager does not know (an optional one, turned off)
    is reported `not-found` and skipped: `try-restart` exits 5 on it while
    still restarting the others.
    """
    states: dict[str, str] = {}
    loaded: list[str] = []
    for unit in profile.units:
        if await load_state(unit) == "not-found":
            states[unit] = "not-found"
        else:
            loaded.append(unit)
    if not loaded:
        return states
    await run([SYSTEMCTL, "--user", "try-restart", *loaded])
    for unit in loaded:
        proc = await anyio.run_process(
            [SYSTEMCTL, "--user", "is-active", unit], check=False
        )
        states[unit] = proc.stdout.decode().strip()
        if states[unit] == "failed":
            await anyio.run_process(
                [JOURNALCTL, "--user", "--unit", unit, "--lines", "30", "--no-pager"],
                check=False,
                stdout=sys.stderr.buffer,
            )
    return states


async def deploy(profile: Profile, *, restart_units: bool) -> Outcome:
    previous = profile.current()
    target = await build(profile)
    changed = target != previous
    if changed:
        await switch(profile, target)
    states = await restart(profile) if restart_units and changed else {}
    return Outcome(profile.name, previous, target, changed, states)


async def rollback(profile: Profile) -> Outcome:
    previous = profile.current()
    await run([NIX_ENV, "--profile", str(profile.path), "--rollback"])
    return Outcome(
        profile.name, previous, profile.current(), True, await restart(profile)
    )


async def reset(profile: Profile) -> Outcome:
    previous = profile.current()
    changed = previous != profile.pinned
    if changed:
        await switch(profile, profile.pinned)
    states = await restart(profile) if changed else {}
    return Outcome(profile.name, previous, profile.pinned, changed, states)


def listing(profiles: dict[str, Profile]) -> list[dict[str, object]]:
    return [
        {
            "name": p.name,
            "profile": str(p.path),
            "current": p.current(),
            "pinned": p.pinned,
            "dev": p.current() != p.pinned,
            "mode": p.mode,
            "build": f"{p.file}#{p.attr}",
            "units": list(p.units),
        }
        for p in profiles.values()
    ]


def parse(argv: Sequence[str], names: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="devprofile", description=__doc__.splitlines()[0]
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser(
        "list", help="every profile: what it runs, and whether that is the pinned build"
    )
    deploy_p = sub.add_parser(
        "deploy",
        help="build from the working tree, switch the profile, restart its units",
    )
    deploy_p.add_argument("name", choices=names)
    deploy_p.add_argument(
        "--no-restart", dest="restart", action="store_false", help="switch only"
    )
    for command, text in (
        ("rollback", "back to the profile's previous generation, then restart"),
        ("reset", "back to the build the system configuration pins, then restart"),
    ):
        sub.add_parser(command, help=text).add_argument("name", choices=names)
    return parser.parse_args(argv)


async def main(argv: Sequence[str]) -> int:
    profiles = load()
    args = parse(argv, sorted(profiles))
    if args.command == "list":
        sys.stdout.write(json.dumps(listing(profiles), indent=2) + "\n")
        return 0
    profile = profiles[args.name]
    try:
        if args.command == "deploy":
            outcome = await deploy(profile, restart_units=args.restart)
        elif args.command == "rollback":
            outcome = await rollback(profile)
        else:
            outcome = await reset(profile)
    except StepError as error:
        sys.stderr.write(f"devprofile: {error}\n")
        return 1
    sys.stdout.write(json.dumps(asdict(outcome), indent=2) + "\n")
    return 1 if "failed" in outcome.units.values() else 0


if __name__ == "__main__":
    sys.exit(anyio.run(main, sys.argv[1:]))
