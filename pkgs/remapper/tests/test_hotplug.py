"""A real uinput numpad, unplugged and plugged back. Needs /dev/uinput and udev."""

from __future__ import annotations

import os

import anyio
import pytest
from evdev import InputDevice, UInput, ecodes
from remapper.config import Config
from remapper.daemon import serve

pytestmark = pytest.mark.skipif(
    not os.access("/dev/uinput", os.W_OK), reason="needs a writable /dev/uinput"
)

VENDOR, PRODUCT = 0x1234, 0x5678
NAME = "remapper-test-numpad"
CONFIG = Config.model_validate(
    {
        "numpad": {
            "vendor": f"{VENDOR:04x}",
            "product": f"{PRODUCT:04x}",
            "keys": ["KEY_KP0"],
        },
        "domain": "test",
        "bindings": [
            {"key": "KEY_KP0", "action": {"do": "tap", "key": "KEY_F24"}},
            {"key": "KEY_KP1", "action": {"do": "vm-start"}},
        ],
    }
)


class Taps:
    def __init__(self) -> None:
        self.keys: list[int] = []
        self.changed = anyio.Event()

    def write(self, etype: int, code: int, value: int) -> None:
        if etype == ecodes.EV_KEY and value == 1:
            self.keys.append(code)
            self.changed.set()
            self.changed = anyio.Event()

    def syn(self) -> None:
        pass


async def never_run(argv: object, stdin: object = None) -> str | None:
    raise AssertionError(argv)


def numpad() -> UInput:
    return UInput(
        {ecodes.EV_KEY: [ecodes.KEY_KP0, ecodes.KEY_KP1]},
        name=NAME,
        vendor=VENDOR,
        product=PRODUCT,
    )


def tap(dev: UInput, key: int) -> None:
    for value in (1, 0):
        dev.write(ecodes.EV_KEY, key, value)
        dev.syn()


async def grabbed(dev: UInput) -> bool:
    """Whether the daemon holds the node: a second grab then fails with EBUSY."""
    if dev.device is None:
        return False
    probe = InputDevice(dev.device.path)
    try:
        probe.grab()
    except OSError:
        return True
    else:
        probe.ungrab()
        return False
    finally:
        probe.close()


async def until_grabbed(dev: UInput) -> None:
    # The grab is in another task and signals nothing; a 20 ms poll bounded by
    # fail_after is the only way to see it from outside.
    with anyio.fail_after(5):
        while not await grabbed(dev):  # noqa: ASYNC110
            await anyio.sleep(0.02)


async def tapped(taps: Taps, dev: UInput) -> int:
    changed = taps.changed
    tap(dev, ecodes.KEY_KP0)
    with anyio.fail_after(5):
        await changed.wait()
    return taps.keys[-1]


@pytest.mark.anyio
async def test_regrabs_after_replug() -> None:
    taps = Taps()
    async with anyio.create_task_group() as tg:
        tg.start_soon(serve, CONFIG, taps, never_run)
        for _ in range(3):
            with numpad() as dev:
                await until_grabbed(dev)
                assert await tapped(taps, dev) == ecodes.KEY_F24
        tg.cancel_scope.cancel()
    assert taps.keys == [ecodes.KEY_F24] * 3


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"
