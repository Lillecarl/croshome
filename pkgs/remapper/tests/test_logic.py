from __future__ import annotations

from typing import TYPE_CHECKING

import anyio
import pytest
from evdev import ecodes
from remapper.actions import Actions, hostdev, parse_vcp, plugged, sound_volume
from remapper.chord import Chords
from remapper.config import Binding, Brightness, Config, Tap, UsbAttach, VmStart

if TYPE_CHECKING:
    from collections.abc import Sequence
    from pathlib import Path

DOWN, UP, HOLD = 1, 0, 2
KP0, KP1, KP2 = ecodes.KEY_KP0, ecodes.KEY_KP1, ecodes.KEY_KP2

CONFIG = {
    "numpad": {"vendor": "062a", "product": "4101", "keys": ["KEY_KP0"]},
    "domain": "win",
    "vmUsb": [
        {"vendor": "1c4f", "product": "0083"},
        {"vendor": "2dc8", "product": "301c"},
    ],
    "brightness": {"primary": "A", "follower": "B", "offset": 25},
    "bindings": [
        {"key": "KEY_KP0", "action": {"do": "tap", "key": "KEY_SPACE"}},
        {"key": "KEY_KP1", "hold": "KEY_KP0", "action": {"do": "vm-start"}},
        {"key": "KEY_KP1", "action": {"do": "usb-attach"}},
        {
            "key": "KEY_KPPLUS",
            "hold": "KEY_KP0",
            "action": {"do": "brightness", "delta": 10},
        },
    ],
}


def config() -> Config:
    return Config.model_validate(CONFIG)


def press(chords: Chords, *steps: tuple[int, int]) -> list[str]:
    return [a.do for key, value in steps if (a := chords.feed(key, value))]


def test_tap_fires_on_release() -> None:
    chords = Chords.of(config().bindings)
    assert press(chords, (KP1, DOWN), (KP1, HOLD), (KP1, UP)) == ["usb-attach"]


def test_modifier_picks_its_binding_and_does_not_tap() -> None:
    chords = Chords.of(config().bindings)
    steps = [(KP0, DOWN), (KP1, DOWN), (KP1, UP), (KP0, UP)]
    assert press(chords, *steps) == ["vm-start"]


def test_modifier_alone_is_a_tap() -> None:
    chords = Chords.of(config().bindings)
    assert press(chords, (KP0, DOWN), (KP0, UP)) == ["tap"]


def test_modifier_without_binding_fires_nothing() -> None:
    chords = Chords.of(config().bindings)
    assert press(chords, (KP0, DOWN), (KP2, DOWN), (KP2, UP), (KP0, UP)) == []


def test_release_without_press_after_reset() -> None:
    chords = Chords.of(config().bindings)
    chords.feed(KP0, DOWN)
    chords.reset()
    assert press(chords, (KP0, UP), (KP1, DOWN), (KP1, UP)) == ["usb-attach"]


def test_config_rejects_unknown_key() -> None:
    bad = {**CONFIG, "bindings": [{"key": "KEY_NOPE", "action": {"do": "vm-start"}}]}
    with pytest.raises(ValueError, match="KEY_NOPE"):
        Config.model_validate(bad)


def test_config_actions() -> None:
    actions = [b.action for b in config().bindings]
    assert [type(a) for a in actions] == [Tap, VmStart, UsbAttach, Brightness]
    assert Binding.model_validate(CONFIG["bindings"][1]).hold == "KEY_KP0"


def test_parse_vcp() -> None:
    assert parse_vcp("VCP 10 C 50 100\n") == (50, 100)
    with pytest.raises(ValueError, match="no continuous"):
        parse_vcp("VCP 60 SNC x0f\n")


def test_sound_volume() -> None:
    assert sound_volume(0.0) == pytest.approx(1.0)
    assert sound_volume(1.0) == pytest.approx(0.2)


def test_hostdev() -> None:
    xml = hostdev(config().vm_usb[0]).decode()
    assert '<vendor id="0x1c4f"/>' in xml
    assert '<product id="0x0083"/>' in xml


class Recorder:
    def __init__(self, replies: dict[str, str] | None = None) -> None:
        self.calls: list[list[str]] = []
        self.replies = replies or {}

    async def __call__(
        self, argv: Sequence[str], stdin: bytes | None = None
    ) -> str | None:
        self.calls.append(list(argv))
        return self.replies.get(" ".join(argv), "")


def fake_usb(root: Path, *ids: tuple[str, str]) -> Path:
    for n, (vendor, product) in enumerate(ids):
        dev = root / f"1-{n}"
        dev.mkdir()
        (dev / "idVendor").write_text(f"{vendor}\n")
        (dev / "idProduct").write_text(f"{product}\n")
    (root / "usb1").mkdir()  # a root hub entry with no ids of its own is skipped
    return root


def test_plugged(tmp_path: Path) -> None:
    assert plugged(fake_usb(tmp_path, ("1c4f", "0083"))) == {("1c4f", "0083")}


def test_attach_skips_absent_devices(tmp_path: Path) -> None:
    runner = Recorder()
    actions = Actions(config(), None, runner, fake_usb(tmp_path, ("1c4f", "0083")))
    anyio.run(actions, UsbAttach())
    assert runner.calls == [
        [
            "virsh",
            "--connect",
            "qemu:///system",
            "attach-device",
            "win",
            "/dev/stdin",
            "--live",
        ]
    ]


def test_brightness_clamps_and_offsets() -> None:
    runner = Recorder({"ddcutil --model A getvcp 0x10 --brief": "VCP 10 C 95 100\n"})
    anyio.run(Actions(config(), None, runner), Brightness(delta=10))
    assert runner.calls[1:] == [
        ["ddcutil", "--model", "A", "setvcp", "0x10", "100"],
        ["ddcutil", "--model", "B", "setvcp", "0x10", "100"],
    ]
