"""A real uinput numpad, unplugged and plugged back. Needs /dev/uinput and udev."""

from __future__ import annotations

import json
import os

import anyio
import pytest
from evdev import ecodes
from remapper.config import parse
from remapper.daemon import serve
from remapper.testing import NUMPAD, Sink, numpad, tap, until_grabbed

pytestmark = pytest.mark.skipif(
    not os.access("/dev/uinput", os.W_OK), reason="needs a writable /dev/uinput"
)

CONFIG = parse(
    json.dumps(
        {
            "numpad": NUMPAD,
            # F24: on a live desktop the compositor reads the keyboard.
            "bindings": [
                {"key": "KEY_KP0", "actions": [{"do": "tap", "key": "KEY_F24"}]}
            ],
        }
    ),
    {},
)


@pytest.mark.anyio
async def test_regrabs_after_replug() -> None:
    taps = Sink()
    async with anyio.create_task_group() as tg:
        tg.start_soon(serve, CONFIG, {}, taps)
        for _ in range(3):
            with numpad() as dev:
                await until_grabbed(dev)
                changed = taps.changed
                tap(dev, ecodes.KEY_KP0)
                with anyio.fail_after(5):
                    await changed.wait()
        tg.cancel_scope.cancel()
    assert taps.presses() == [ecodes.KEY_F24] * 3


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"
