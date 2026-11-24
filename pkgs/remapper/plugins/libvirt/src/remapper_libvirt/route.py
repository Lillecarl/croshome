"""Where the forwarded keyboard and mouse go: the host, or the VM's evdev input."""

from __future__ import annotations

import contextlib
import logging
from dataclasses import dataclass, field
from enum import Enum
from typing import TYPE_CHECKING, Final, Protocol

from evdev import KeyEvent, ecodes

from .caps import CapsMap

if TYPE_CHECKING:
    from collections.abc import Callable

    from evdev import InputEvent

log = logging.getLogger(__name__)

GUEST_NAME: Final = "remapper guest"
HOST_NAME: Final = "remapper host"
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


class HostWriter(Writer, Protocol):
    def close(self) -> None: ...


def forwarded(event: InputEvent) -> bool:
    """Keys, motion and the reports that end them; not MSC_SCAN, LEDs or SYN_DROPPED."""
    if event.type == ecodes.EV_SYN:
        return event.code == ecodes.SYN_REPORT
    return event.type in (ecodes.EV_KEY, ecodes.EV_REL)


@dataclass
class Output:
    """A writer, and the keys down in it."""

    writer: Writer
    down: set[int] = field(default_factory=set)

    def write(self, etype: int, code: int, value: int) -> None:
        if etype == ecodes.EV_KEY:
            if value == KeyEvent.key_up:
                self.down.discard(code)
            else:
                self.down.add(code)
        self.writer.write(etype, code, value)

    def release(self) -> None:
        for key in sorted(self.down):
            self.writer.write(ecodes.EV_KEY, key, KeyEvent.key_up)
        if self.down:
            self.writer.syn()
        self.down.clear()


@dataclass(eq=False)
class Node:
    dev: Grabbable
    # What the host reads instead of the device; None leaves it the device.
    host: HostWriter | None = None
    grabbed: bool = False
    caps: CapsMap = field(default_factory=CapsMap)

    def __post_init__(self) -> None:
        self.output = None if self.host is None else Output(self.host)

    def grab(self) -> None:
        if self.grabbed:
            return
        try:
            self.dev.grab()
        except OSError as e:
            log.warning("cannot grab %s: %s", self.dev, e)
        else:
            self.grabbed = True

    def ungrab(self) -> None:
        if self.grabbed:
            self.grabbed = False
            with contextlib.suppress(OSError):
                self.dev.ungrab()

    def to_host(self, event: InputEvent) -> None:
        # Ungrabbed, the host reads the device too and would see each key twice.
        if self.output is None or not self.grabbed:
            return
        if event.type != ecodes.EV_KEY:
            self.output.write(event.type, event.code, event.value)
            return
        keys = self.caps.feed(event.code, event.value, event.timestamp())
        for i, (key, value) in enumerate(keys):
            if i:
                self.output.writer.syn()
            self.output.write(ecodes.EV_KEY, key, value)


@dataclass
class Router:
    """In the guest the devices are grabbed and their events go to `guest`,
    which the VM reads.

    On the host they are ungrabbed and the compositor reads them itself, or
    with `host` they stay grabbed and it reads the device `host` makes for
    each, which has Caps Lock remapped. Keys still down on the side that
    loses the input are released there.
    """

    guest: Writer
    path: str
    host: Callable[[Grabbable], HostWriter] | None = None
    nodes: list[Node] = field(default_factory=list)
    mode: Mode = Mode.HOST

    def __post_init__(self) -> None:
        self.output = Output(self.guest)

    def add(self, dev: Grabbable) -> Node:
        node = Node(dev, None if self.host is None else self.host(dev))
        self.nodes.append(node)
        if self.mode is Mode.GUEST or node.host is not None:
            node.grab()
        return node

    def remove(self, node: Node) -> None:
        self.nodes = [n for n in self.nodes if n is not node]
        if node.host is not None:
            # Closing the device releases its keys.
            node.host.close()

    def handle(self, event: InputEvent, node: Node | None = None) -> None:
        if not forwarded(event):
            return
        if self.mode is Mode.GUEST:
            self.output.write(event.type, event.code, event.value)
        elif node is not None:
            node.to_host(event)

    def to_guest(self) -> None:
        if self.mode is Mode.GUEST:
            return
        for node in self.nodes:
            node.grab()
            node.caps.reset()
            if node.output is not None:
                node.output.release()
        self.mode = Mode.GUEST
        log.info("input to the VM")

    def to_host(self) -> None:
        if self.mode is Mode.HOST:
            return
        self.mode = Mode.HOST
        self.output.release()
        for node in self.nodes:
            if node.host is None:
                node.ungrab()
        log.info("input to the host")
