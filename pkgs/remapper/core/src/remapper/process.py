"""Commands that plugins run: logged on failure, never raised."""

from __future__ import annotations

import logging
import subprocess
from typing import TYPE_CHECKING, Final, Protocol

import anyio

if TYPE_CHECKING:
    from collections.abc import Sequence

log = logging.getLogger(__name__)

# ddcutil takes 1-3 s per command on some monitors; virsh attach waits on QEMU.
TIMEOUT: Final = 20


class Runner(Protocol):
    async def __call__(
        self, argv: Sequence[str], stdin: bytes | None = None
    ) -> str | None: ...


async def run(argv: Sequence[str], stdin: bytes | None = None) -> str | None:
    """stdout of a command that succeeded; None, logged, for one that failed."""
    try:
        with anyio.fail_after(TIMEOUT):
            done = await anyio.run_process(
                argv, input=stdin, check=False, stderr=subprocess.PIPE
            )
    except (OSError, TimeoutError) as e:
        log.warning("%s: %s", argv[0], e)
        return None
    if done.returncode != 0:
        log.warning(
            "%s failed (%d): %s",
            " ".join(argv),
            done.returncode,
            done.stderr.decode().strip(),
        )
        return None
    return done.stdout.decode()
