"""Choosing where the file tools are rooted.

`FileSystem` from pydantic-ai-harness wants a root and refuses to resolve
outside it. A shell has no project, only a cwd, so something has to pick.

The rule is small on purpose: the enclosing repository if there is one, else
the cwd. A repository is almost always the thing you mean -- ask about "the
tests" from `src/` and you want the tree, not that one directory.

This is a convenience, not a security boundary. The `run_xonsh` tool next door
runs whatever the model asks for, subject to your approval, so a root that
excluded something would not actually keep it out of reach. Human in the loop is
the control; this just keeps `search_files` pointed somewhere useful.
"""

from __future__ import annotations

import os
from pathlib import Path


def repository_root(start: Path) -> Path | None:
    """The nearest ancestor holding a `.git`, or `None`.

    Walks rather than shelling out to `git rev-parse`: this runs on the way to
    every request, and a subprocess per prompt is not worth a directory check.
    """
    for candidate in (start, *start.parents):
        if (candidate / ".git").exists():
            return candidate
    return None


def choose_root(cwd: Path | None = None) -> Path:
    """Where file tools operate: the enclosing repository, else the cwd."""
    cwd = (cwd or Path.cwd()).resolve()
    return repository_root(cwd) or cwd


def root_from_env(getenv=os.environ.get) -> Path | None:
    """`$XONTRIB_PAI_ROOT`, expanded, or `None` to fall back to `choose_root`."""
    raw = getenv("XONTRIB_PAI_ROOT")
    if not raw:
        return None
    return Path(raw).expanduser().resolve()
