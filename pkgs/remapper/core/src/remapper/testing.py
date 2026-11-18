"""Fakes and uinput helpers for the tests of the daemon and its plugins."""

from __future__ import annotations

from typing import TYPE_CHECKING

import anyio
from evdev import InputDevice, UInput, ecodes

if TYPE_CHECKING:
    from collections.abc import Sequence

VENDOR, PRODUCT = 0x1234, 0x5678
NUMPAD = {
    "vendor": f"{VENDOR:04x}",
    "product": f"{PRODUCT:04x}",
    "keys": ["KEY_KP0"],
}


class Recorder:
    """A Runner that records each command and answers from `replies`, or ""."""

    def __init__(self, replies: dict[str, str] | None = None) -> None:
        self.calls: list[list[str]] = []
        self.replies = replies or {}

    async def __call__(
        self, argv: Sequence[str], stdin: bytes | None = None
    ) -> str | None:
        self.calls.append(list(argv))
        return self.replies.get(" ".join(argv), "")


class Sink:
    """A Keyboard or a Writer that keeps what was written."""

    def __init__(self) -> None:
        self.events: list[tuple[int, int, int]] = []
        self.changed = anyio.Event()

    def write(self, etype: int, code: int, value: int) -> None:
        self.events.append((etype, code, value))
        self.changed.set()
        self.changed = anyio.Event()

    def syn(self) -> None:
        self.write(ecodes.EV_SYN, ecodes.SYN_REPORT, 0)

    def presses(self) -> list[int]:
        return [c for t, c, v in self.events if t == ecodes.EV_KEY and v == 1]


def numpad() -> UInput:
    return UInput(
        {ecodes.EV_KEY: [ecodes.KEY_KP0, ecodes.KEY_KP1, ecodes.KEY_KP2]},
        name="remapper-test-numpad",
        vendor=VENDOR,
        product=PRODUCT,
    )


def tap(dev: UInput, key: int) -> None:
    for value in (1, 0):
        dev.write(ecodes.EV_KEY, key, value)
        dev.syn()


def grabbed(dev: UInput) -> bool:
    """Whether someone holds the node: a second grab then fails with EBUSY."""
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


async def until_grabbed(dev: UInput, *, want: bool = True) -> None:
    # The grab is in another task and signals nothing; a 20 ms poll bounded by
    # fail_after is the only way to see it from outside.
    with anyio.fail_after(5):
        while grabbed(dev) != want:  # noqa: ASYNC110
            await anyio.sleep(0.02)
