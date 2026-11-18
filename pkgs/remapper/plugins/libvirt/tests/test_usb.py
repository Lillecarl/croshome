from __future__ import annotations

from typing import TYPE_CHECKING

import anyio
from remapper.config import UsbDevice
from remapper.testing import Recorder
from remapper_libvirt import Libvirt
from remapper_libvirt.config import LibvirtSettings, UsbAttach
from remapper_libvirt.plugin import plugged
from remapper_libvirt.vm import hostdev

if TYPE_CHECKING:
    from pathlib import Path

SETTINGS = LibvirtSettings.model_validate(
    {
        "domain": "win",
        "vmUsb": [
            {"vendor": "1c4f", "product": "0083"},
            {"vendor": "2dc8", "product": "301c"},
        ],
    }
)


def fake_usb(root: Path, *ids: tuple[str, str]) -> Path:
    for n, (vendor, product) in enumerate(ids):
        dev = root / f"1-{n}"
        dev.mkdir()
        (dev / "idVendor").write_text(f"{vendor}\n")
        (dev / "idProduct").write_text(f"{product}\n")
    (root / "usb1").mkdir()  # a root hub entry with no ids of its own is skipped
    return root


def test_hostdev() -> None:
    xml = hostdev(UsbDevice(vendor="1c4f", product="0083")).decode()
    assert '<vendor id="0x1c4f"/>' in xml
    assert '<product id="0x0083"/>' in xml


def test_plugged(tmp_path: Path) -> None:
    assert plugged(fake_usb(tmp_path, ("1c4f", "0083"))) == {("1c4f", "0083")}


def test_attach_skips_absent_devices(tmp_path: Path) -> None:
    runner = Recorder()
    root = fake_usb(tmp_path, ("1c4f", "0083"))
    anyio.run(Libvirt(SETTINGS, runner, usb_root=root), UsbAttach())
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
