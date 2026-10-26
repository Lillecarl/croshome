"""pyjj identity hook: who commits depends on the repository and the clock.

| repository                               | work hours   | off hours    |
| ---------------------------------------- | ------------ | ------------ |
| personal (`personal-repos`)              | private      | private      |
| employee (a remote on `hosts`, a path in | work         | probono      |
|   `employee-repos`, or the repo flag)    |              |              |
| anything else                            | work         | private      |

Work hours are Monday to Friday, 08:00 to 17:00 Europe/Stockholm time,
whatever the machine's own zone. Each identity
signs with its own key, so an address and a key always name the same person.

Everything else comes from the `[work-identity]` table that ../vcs.nix
writes. Without one the hook answers nothing and the plain config applies.
Mark one repository as employee work without a rebuild:

    pyjj config set --repo work-identity.employee true

Only pyjj runs this. `jj` itself still commits under the plain config.
"""

from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

import pyjj

WORK_DAYS = range(5)
TIMEZONE = ZoneInfo("Europe/Stockholm")
WORK_START, WORK_END = 8, 17

# `git@host:group/repo.git`, the scp-like form git accepts beside URLs.
_SCP_LIKE = re.compile(r"^(?:[^@/]+@)?([^:/]+):")


def is_work_hours(now: datetime) -> bool:
    now = now.astimezone(TIMEZONE)
    return now.weekday() in WORK_DAYS and WORK_START <= now.hour < WORK_END


def remote_host(url: str) -> str | None:
    if "://" in url:
        return urlsplit(url).hostname
    match = _SCP_LIKE.match(url)
    return match.group(1) if match else None


def _under(root: Path, entries: list[str]) -> bool:
    for entry in entries:
        base = Path(entry).expanduser().resolve()
        if root == base or base in root.parents:
            return True
    return False


def classify(settings, root: Path, remotes: dict[str, str]) -> str:
    """`personal`, `employee` or `other`."""
    root = root.resolve()
    if _under(root, settings.get_string_list("work-identity.personal-repos") or []):
        return "personal"
    if settings.get_bool("work-identity.employee"):
        return "employee"
    if _under(root, settings.get_string_list("work-identity.employee-repos") or []):
        return "employee"
    hosts = set(settings.get_string_list("work-identity.hosts") or [])
    if any(remote_host(url) in hosts for url in remotes.values()):
        return "employee"
    return "other"


def choose(settings, kind: str, now: datetime) -> pyjj.Identity | None:
    def identity(which: str) -> pyjj.Identity | None:
        email = settings.get_string(f"work-identity.{which}-email")
        if email is None:
            return None
        key = settings.get_string(f"work-identity.{which}-signing-key")
        return pyjj.Identity(email=email, signing_key=key)

    if kind == "personal":
        return identity("private")
    if is_work_hours(now):
        return identity("work")
    return identity("probono" if kind == "employee" else "private")


@pyjj.identity
def work_identity(ctx: pyjj.IdentityContext) -> pyjj.Identity | None:
    if ctx.settings.get_string("work-identity.work-email") is None:
        return None
    kind = classify(ctx.settings, ctx.workspace_root, ctx.remotes)
    return choose(ctx.settings, kind, datetime.now(TIMEZONE))
