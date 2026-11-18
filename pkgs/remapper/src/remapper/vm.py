"""libvirt device XML and events. No IO."""

from __future__ import annotations

import xml.etree.ElementTree as ET
from typing import TYPE_CHECKING, Final

if TYPE_CHECKING:
    from .config import UsbDevice

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


def our_inputs(domain_xml: str, path: str) -> tuple[bool, list[bytes]]:
    """Whether `path` is attached, and the XML of our inputs on other paths: a previous run's."""
    attached = False
    stale: list[bytes] = []
    for node in ET.fromstring(domain_xml).iterfind("./devices/input[@type='evdev']"):
        alias = node.find("alias")
        if alias is None or alias.get("name") != ALIAS:
            continue
        source = node.find("source")
        if source is not None and source.get("dev") == path:
            attached = True
        else:
            stale.append(ET.tostring(node))
    return attached, stale


def stopped(event_line: str) -> bool:
    """Whether a `virsh event --event lifecycle` line reports the domain gone.

    The lines read `event 'lifecycle' for domain 'win11-4': Stopped Destroyed`.
    """
    _, sep, rest = event_line.rpartition("': ")
    return bool(sep) and rest.split()[:1] in (["Stopped"], ["Crashed"])
