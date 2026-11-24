"""The libvirt plugin's settings and actions."""

from __future__ import annotations

from typing import Literal

from pydantic import Field
from remapper.config import Action, Match, Model, UsbDevice

HidKind = Literal["keyboard", "mouse"]


class LibvirtSettings(Model):
    domain: str
    libvirt_uri: str = "qemu:///system"
    vm_usb: list[UsbDevice] = Field(default_factory=list)
    # Keyboards and mice that reach the VM through an evdev input, not USB.
    forward: list[Match] = Field(default_factory=list)
    # On the host too, take `forward` over and make Caps Lock Ctrl, Esc on a
    # tap, and Caps Lock together with Esc.
    caps_as_ctrl_esc: bool = False
    # The emulated USB devices the VM reads `forward` through. A device
    # with no kind here falls through to PS/2 or virtio.
    usb_hid: list[HidKind] = Field(default_factory=lambda: ["keyboard", "mouse"])


class VmStart(Action):
    do: Literal["vm-start"] = "vm-start"


class VmStop(Action):
    do: Literal["vm-stop"] = "vm-stop"


class UsbAttach(Action):
    do: Literal["usb-attach"] = "usb-attach"


class UsbDetach(Action):
    do: Literal["usb-detach"] = "usb-detach"


class Guest(Action):
    """The forwarded devices and the vmUsb devices to the VM."""

    do: Literal["guest"] = "guest"


class Host(Action):
    """Both back to the host."""

    do: Literal["host"] = "host"
