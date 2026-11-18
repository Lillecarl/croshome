"""Where the forwarded keyboard and mouse go: the host, or the VM's evdev input."""

from __future__ import annotations

import contextlib
import logging
from dataclasses import dataclass, field
from enum import Enum
from typing import TYPE_CHECKING, Final, Protocol

from evdev import KeyEvent, ecodes

if TYPE_CHECKING:
    from evdev import InputEvent

log = logging.getLogger(__name__)

GUEST_NAME: Final = "remapper guest"
# Every keyboard key up to KEY_MICMUTE, and the mouse buttons. Fixed at
# creation, so it covers whichever keyboard and mouse are plugged in later.
GUEST_KEYS: Final = [
    *range(ecodes.KEY_ESC, ecodes.KEY_MICMUTE + 1),
    *range(ecodes.BTN_LEFT, ecodes.BTN_TASK + 1),
]
GUEST_RELS: Final = [
    ecodes.REL_X,
    ecodes.REL_Y,
    ecodes.REL_HWHEEL,
    ecodes.REL_WHEEL,
    ecodes.REL_WHEEL_HI_RES,
    ecodes.REL_HWHEEL_HI_RES,
]


class Mode(Enum):
    HOST = "host"
    GUEST = "guest"


class Grabbable(Protocol):
    def grab(self) -> None: ...
    def ungrab(self) -> None: ...


class Writer(Protocol):
    def write(self, etype: int, code: int, value: int) -> None: ...
    def syn(self) -> None: ...


def forwarded(event: InputEvent) -> bool:
    """Keys, motion and the reports that end them; not MSC_SCAN, LEDs or SYN_DROPPED."""
    if event.type == ecodes.EV_SYN:
        return event.code == ecodes.SYN_REPORT
    return event.type in (ecodes.EV_KEY, ecodes.EV_REL)


@dataclass
class Router:
    """On the host the devices are ungrabbed and niri reads them itself.

    In the guest they are grabbed and their events go to `guest`, which the
    VM reads. Keys still down in the guest are released on the way back.
    """

    guest: Writer
    path: str
    # A list: evdev.InputDevice defines __eq__ and no __hash__.
    nodes: list[Grabbable] = field(default_factory=list)
    mode: Mode = Mode.HOST
    down: set[int] = field(default_factory=set)

    def add(self, dev: Grabbable) -> None:
        self.nodes.append(dev)
        if self.mode is Mode.GUEST:
            self._grab(dev)

    def remove(self, dev: Grabbable) -> None:
        self.nodes = [n for n in self.nodes if n is not dev]

    def handle(self, event: InputEvent) -> None:
        if self.mode is not Mode.GUEST or not forwarded(event):
            return
        if event.type == ecodes.EV_KEY:
            if event.value == KeyEvent.key_up:
                self.down.discard(event.code)
            else:
                self.down.add(event.code)
        self.guest.write(event.type, event.code, event.value)

    def to_guest(self) -> None:
        if self.mode is Mode.GUEST:
            return
        for dev in self.nodes:
            self._grab(dev)
        self.mode = Mode.GUEST
        log.info("input to the VM")

    def to_host(self) -> None:
        if self.mode is Mode.HOST:
            return
        self.mode = Mode.HOST
        for key in sorted(self.down):
            self.guest.write(ecodes.EV_KEY, key, KeyEvent.key_up)
        if self.down:
            self.guest.syn()
        self.down.clear()
        for dev in self.nodes:
            # Not grabbed when its grab failed; ungrab then raises EINVAL.
            with contextlib.suppress(OSError):
                dev.ungrab()
        log.info("input to the host")

    @staticmethod
    def _grab(dev: Grabbable) -> None:
        try:
            dev.grab()
        except OSError as e:
            log.warning("cannot grab %s: %s", dev, e)
