"""The numpad routes a real uinput keyboard to the guest and back. Needs /dev/uinput and udev."""

from __future__ import annotations

import json
import os
from typing import TYPE_CHECKING

import anyio
import pytest
from evdev import UInput, ecodes
from remapper.config import parse
from remapper.daemon import serve
from remapper.testing import (
    NUMPAD,
    PRODUCT,
    VENDOR,
    Sink,
    grabbed,
    numpad,
    tap,
    until_grabbed,
)
from remapper_libvirt import Libvirt

if TYPE_CHECKING:
    from collections.abc import Sequence

pytestmark = pytest.mark.skipif(
    not os.access("/dev/uinput", os.W_OK), reason="needs a writable /dev/uinput"
)

CONFIG = parse(
    json.dumps(
        {
            "numpad": NUMPAD,
            "plugins": {
                "libvirt": {
                    "domain": "test",
                    "forward": [
                        {"vendor": f"{VENDOR:04x}", "product": f"{PRODUCT + 1:04x}"}
                    ],
                }
            },
            "bindings": [
                {"key": "KEY_KP1", "actions": [{"do": "guest"}]},
                {"key": "KEY_KP2", "actions": [{"do": "host"}]},
            ],
        }
    ),
    {"libvirt": Libvirt},
)


async def virsh(argv: Sequence[str], stdin: bytes | None = None) -> str | None:
    return "<domain><devices/></domain>" if argv[3] == "dumpxml" else ""


@pytest.mark.anyio
async def test_numpad_routes_a_keyboard_to_the_guest_and_back() -> None:
    sink = Sink()
    plugin = Libvirt(
        CONFIG.plugins["libvirt"], virsh, guest=(sink, "/dev/input/fake"), follow=False
    )
    # F24 alone: on a live desktop the compositor reads it while it is ungrabbed.
    keyboard = UInput(
        {ecodes.EV_KEY: [ecodes.KEY_F24]},
        name="remapper-test-keyboard",
        vendor=VENDOR,
        product=PRODUCT + 1,
    )
    f24_down = (ecodes.EV_KEY, ecodes.KEY_F24, 1)
    async with anyio.create_task_group() as tg:
        tg.start_soon(serve, CONFIG, {"libvirt": plugin}, None)
        with keyboard, numpad() as pad:
            await until_grabbed(pad)
            assert not grabbed(keyboard)
            tap(keyboard, ecodes.KEY_F24)
            tap(pad, ecodes.KEY_KP1)
            # Keys before the switch stay on the host; the poll waits out the switch.
            with anyio.fail_after(5):
                while f24_down not in sink.events:
                    tap(keyboard, ecodes.KEY_F24)
                    await anyio.sleep(0.05)
            assert grabbed(keyboard)
            tap(pad, ecodes.KEY_KP2)
            await until_grabbed(keyboard, want=False)
            sink.events.clear()
            tap(keyboard, ecodes.KEY_F24)
            await anyio.sleep(0.2)
            assert sink.events == []
        tg.cancel_scope.cancel()


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"
