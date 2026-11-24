from __future__ import annotations

from typing import TYPE_CHECKING

from evdev import InputEvent, ecodes
from remapper.testing import Sink
from remapper_libvirt.caps import CapsMap
from remapper_libvirt.route import Router

if TYPE_CHECKING:
    from collections.abc import Sequence

CAPS, CTRL, ESC, A = (
    ecodes.KEY_CAPSLOCK,
    ecodes.KEY_LEFTCTRL,
    ecodes.KEY_ESC,
    ecodes.KEY_A,
)


def fed(*events: tuple[int, int, float]) -> list[tuple[int, int]]:
    caps = CapsMap()
    return [out for event in events for out in caps.feed(*event)]


def test_tap_is_ctrl_then_esc() -> None:
    assert fed((CAPS, 1, 0), (CAPS, 0, 0.1)) == [
        (CTRL, 1),
        (CTRL, 0),
        (ESC, 1),
        (ESC, 0),
    ]


def test_a_long_press_or_a_chord_is_ctrl_alone() -> None:
    assert fed((CAPS, 1, 0), (CAPS, 2, 0.4), (CAPS, 0, 0.6)) == [
        (CTRL, 1),
        (CTRL, 2),
        (CTRL, 0),
    ]
    assert fed((CAPS, 1, 0), (A, 1, 0.1), (A, 0, 0.2), (CAPS, 0, 0.3)) == [
        (CTRL, 1),
        (A, 1),
        (A, 0),
        (CTRL, 0),
    ]


def test_caps_and_esc_is_caps_lock() -> None:
    assert fed((CAPS, 1, 0), (ESC, 1, 0.1), (ESC, 0, 0.2), (CAPS, 0, 0.3)) == [
        (CTRL, 1),
        (CAPS, 1),
        (CAPS, 0),
        (CTRL, 0),
    ]


def test_esc_alone_passes() -> None:
    assert fed((ESC, 1, 0), (ESC, 0, 0.1)) == [(ESC, 1), (ESC, 0)]


class HostSink(Sink):
    closed = False

    def close(self) -> None:
        self.closed = True


class Device:
    def __init__(self, *, busy: bool = False) -> None:
        self.busy = busy
        self.grabbed = False

    def grab(self) -> None:
        if self.busy:
            raise OSError
        self.grabbed = True

    def ungrab(self) -> None:
        self.grabbed = False


def key(code: int, value: int) -> InputEvent:
    return InputEvent(0, 0, ecodes.EV_KEY, code, value)


def keys(sink: Sink) -> Sequence[tuple[int, int]]:
    return [(c, v) for t, c, v in sink.events if t == ecodes.EV_KEY]


def test_host_is_remapped_and_the_guest_is_not() -> None:
    guest, host, dev = Sink(), HostSink(), Device()
    router = Router(guest, "/dev/input/event30", lambda _: host)
    node = router.add(dev)
    assert dev.grabbed
    router.handle(key(CAPS, 1), node)
    assert keys(host) == [(CTRL, 1)]
    router.to_guest()
    # Held over the switch: let go on the host.
    assert keys(host) == [(CTRL, 1), (CTRL, 0)]
    router.handle(key(CAPS, 1), node)
    assert keys(guest) == [(CAPS, 1)]
    router.to_host()
    assert keys(guest) == [(CAPS, 1), (CAPS, 0)]
    assert dev.grabbed
    router.remove(node)
    assert host.closed


def test_a_device_not_grabbed_is_not_written_twice() -> None:
    host = HostSink()
    router = Router(Sink(), "/dev/input/event30", lambda _: host)
    node = router.add(Device(busy=True))
    router.handle(key(A, 1), node)
    assert host.events == []
