from __future__ import annotations

import errno
import xml.etree.ElementTree as ET
from typing import TYPE_CHECKING

import anyio
from evdev import InputEvent, ecodes
from remapper.actions import Actions
from remapper.config import Config, Guest, Host
from remapper.route import Mode, Router
from remapper.vm import ALIAS, evdev_input, our_inputs, stopped

if TYPE_CHECKING:
    from collections.abc import Sequence

PATH = "/dev/input/event30"
CONFIG = Config.model_validate(
    {
        "numpad": {"vendor": "062a", "product": "4101"},
        "domain": "win",
        "forward": [{"vendor": "1c4f", "product": "0083"}],
        "bindings": [],
    }
)


class Node:
    def __init__(self, *, busy: bool = False) -> None:
        self.grabbed = False
        self.busy = busy

    def grab(self) -> None:
        if self.busy:
            raise OSError(errno.EBUSY, "busy")
        self.grabbed = True

    def ungrab(self) -> None:
        if not self.grabbed:
            raise OSError(errno.EINVAL, "not grabbed")
        self.grabbed = False


class Sink:
    def __init__(self) -> None:
        self.events: list[tuple[int, int, int]] = []

    def write(self, etype: int, code: int, value: int) -> None:
        self.events.append((etype, code, value))

    def syn(self) -> None:
        self.write(ecodes.EV_SYN, ecodes.SYN_REPORT, 0)


def ev(etype: int, code: int, value: int) -> InputEvent:
    return InputEvent(0, 0, etype, code, value)


def test_host_forwards_nothing_and_grabs_nothing() -> None:
    sink, node = Sink(), Node()
    router = Router(sink, PATH)
    router.add(node)
    router.handle(ev(ecodes.EV_KEY, ecodes.KEY_A, 1))
    assert sink.events == []
    assert not node.grabbed


def test_guest_grabs_forwards_and_releases_on_return() -> None:
    sink, node = Sink(), Node()
    router = Router(sink, PATH)
    router.add(node)
    router.to_guest()
    assert node.grabbed
    for e in [
        ev(ecodes.EV_MSC, ecodes.MSC_SCAN, 4),
        ev(ecodes.EV_KEY, ecodes.KEY_A, 1),
        ev(ecodes.EV_REL, ecodes.REL_X, 5),
        ev(ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
        ev(ecodes.EV_SYN, ecodes.SYN_DROPPED, 0),
    ]:
        router.handle(e)
    assert sink.events == [
        (ecodes.EV_KEY, ecodes.KEY_A, 1),
        (ecodes.EV_REL, ecodes.REL_X, 5),
        (ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
    ]
    sink.events.clear()
    router.to_host()
    assert sink.events == [
        (ecodes.EV_KEY, ecodes.KEY_A, 0),
        (ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
    ]
    assert not node.grabbed
    assert router.mode is Mode.HOST


def test_node_plugged_in_while_in_guest_is_grabbed() -> None:
    router = Router(Sink(), PATH)
    router.to_guest()
    node = Node()
    router.add(node)
    assert node.grabbed


def test_busy_node_does_not_stop_the_switch() -> None:
    router = Router(Sink(), PATH)
    busy, free = Node(busy=True), Node()
    router.add(busy)
    router.add(free)
    router.to_guest()
    router.to_host()
    assert router.mode is Mode.HOST
    assert not free.grabbed


def domain(*inputs: bytes) -> str:
    return f"<domain><devices>{b''.join(inputs).decode()}<input type='mouse' bus='ps2'/></devices></domain>"


def test_our_inputs() -> None:
    old = evdev_input("/dev/input/event9")
    foreign = b'<input type="evdev"><source dev="/dev/input/event3"/></input>'
    assert our_inputs(domain(), PATH) == (False, [])
    assert our_inputs(domain(evdev_input(PATH), foreign), PATH) == (True, [])
    attached, stale = our_inputs(domain(old, foreign), PATH)
    assert not attached
    assert len(stale) == 1
    assert b"event9" in stale[0]
    assert ALIAS.encode() in stale[0]


def test_stopped() -> None:
    assert stopped("event 'lifecycle' for domain 'win11-4': Stopped Destroyed\n")
    assert stopped("event 'lifecycle' for domain 'w': Crashed Panicked")
    assert not stopped("event 'lifecycle' for domain 'win11-4': Started Booted\n")
    assert not stopped("")


class Libvirt:
    """virsh with one running domain, holding whatever was attached to it."""

    def __init__(self, *, running: bool = True, inputs: Sequence[bytes] = ()) -> None:
        self.running = running
        self.inputs = list(inputs)
        self.calls: list[str] = []

    async def __call__(
        self, argv: Sequence[str], stdin: bytes | None = None
    ) -> str | None:
        verb = argv[3]
        self.calls.append(verb)
        if verb == "dumpxml":
            return domain(*self.inputs)
        if not self.running or stdin is None:
            return None
        if verb == "attach-device":
            self.inputs.append(stdin)
        elif verb == "detach-device":
            # libvirt finds an evdev input to detach by its source path.
            self.inputs = [i for i in self.inputs if source(i) != source(stdin)]
        return ""


def source(xml: bytes) -> str | None:
    node = ET.fromstring(xml).find("source")
    return None if node is None else node.get("dev")


def test_guest_attaches_once_and_replaces_a_stale_input() -> None:
    libvirt = Libvirt(inputs=[evdev_input("/dev/input/event9")])
    router = Router(Sink(), PATH)
    actions = Actions(CONFIG, None, libvirt, router=router)
    anyio.run(actions, Guest())
    assert router.mode is Mode.GUEST
    assert libvirt.inputs == [evdev_input(PATH)]
    anyio.run(actions, Host())
    anyio.run(actions, Guest())
    assert libvirt.calls == ["dumpxml", "detach-device", "attach-device", "dumpxml"]


def test_guest_stays_on_host_when_attach_fails() -> None:
    router = Router(Sink(), PATH)
    anyio.run(Actions(CONFIG, None, Libvirt(running=False), router=router), Guest())
    assert router.mode is Mode.HOST
