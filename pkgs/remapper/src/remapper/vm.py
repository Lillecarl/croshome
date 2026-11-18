"""libvirt device XML and events. No IO."""

from __future__ import annotations

import xml.etree.ElementTree as ET
from typing import TYPE_CHECKING, Final

if TYPE_CHECKING:
    from collections.abc import Sequence

    from .config import HidKind, UsbDevice

# User aliases must start with "ua-"; this one finds our input after a restart.
ALIAS: Final = "ua-remapper"
# QEMU toggles its grab on this chord; ctrl-ctrl, the default, is easy to hit in a game.
GRAB_TOGGLE: Final = "ctrl-scrolllock"


def hostdev(device: UsbDevice) -> bytes:
    return (
        '<hostdev mode="subsystem" type="usb" managed="yes"><source>'
        f'<vendor id="0x{device.vendor}"/><product id="0x{device.product}"/>'
        "</source></hostdev>"
    ).encode()


def evdev_input(path: str) -> bytes:
    """The guest device as a libvirt evdev input. QEMU grabs it on open, and passes key repeats on."""
    return (
        f'<input type="evdev"><source dev="{path}" repeat="on" grabToggle="{GRAB_TOGGLE}"/>'
        f'<alias name="{ALIAS}"/></input>'
    ).encode()


def hid_input(kind: HidKind) -> bytes:
    """An emulated USB keyboard or mouse.

    QEMU hands evdev events to the keyboard and mouse activated last, and a
    hot-plugged device activates after every boot-time one. So these win
    over PS/2 and virtio, and Windows drives USB HID with no extra driver.
    QEMU polls them every 8 ms (10 ms at full speed): hw/usb/dev-hid.c.
    """
    return f'<input type="{kind}" bus="usb"><alias name="{ALIAS}-{kind}"/></input>'.encode()


def plan(
    domain_xml: str, path: str, kinds: Sequence[HidKind]
) -> tuple[list[bytes], list[bytes]]:
    """What to detach, then attach, so the VM reads `path` through our USB `kinds`.

    A previous run's evdev input, on another path, is detached. The USB
    devices stay attached until the VM stops: Windows never sees them go.
    """
    hid = {f"{ALIAS}-{kind}": hid_input(kind) for kind in kinds}
    detach: list[bytes] = []
    present: set[str] = set()
    for node in ET.fromstring(domain_xml).iterfind("./devices/input"):
        alias = node.find("alias")
        name = alias.get("name") if alias is not None else None
        if name == ALIAS:
            source = node.find("source")
            if source is not None and source.get("dev") == path:
                present.add(ALIAS)
            else:
                detach.append(ET.tostring(node))
        elif name in hid:
            present.add(name)
    attach = [xml for name, xml in hid.items() if name not in present]
    if ALIAS not in present:
        attach.append(evdev_input(path))
    return detach, attach


def stopped(event_line: str) -> bool:
    """Whether a `virsh event --event lifecycle` line reports the domain gone.

    The lines read `event 'lifecycle' for domain 'win11-4': Stopped Destroyed`.
    """
    _, sep, rest = event_line.rpartition("': ")
    return bool(sep) and rest.split()[:1] in (["Stopped"], ["Crashed"])
