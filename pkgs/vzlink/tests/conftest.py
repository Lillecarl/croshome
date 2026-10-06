"""Shared test helpers: real processes, real sockets, and a hard deadline so a
wedged daemon fails the build instead of hanging it."""

from __future__ import annotations

import shutil
import tempfile

import pytest

DEADLINE = 30.0


@pytest.fixture
def anyio_backend() -> str:
    """trio is not a dependency, so asyncio is the only backend."""
    return "asyncio"


@pytest.fixture
def state_dir():
    """A short directory for the control socket and marker files.

    AF_UNIX paths cannot exceed 104 bytes on darwin, and pytest's tmp_path
    inside a build sandbox runs past that. mkdtemp under TMPDIR stays short
    and unique, so concurrent builds do not collide.
    """
    path = tempfile.mkdtemp(prefix="vzl")
    yield path
    shutil.rmtree(path, ignore_errors=True)
