"""The configuration file, as the NixOS/home-manager module writes it."""

from __future__ import annotations

from pathlib import Path  # noqa: TC003 -- pydantic resolves it at runtime
from typing import Annotated, Literal

from evdev import ecodes
from pydantic import AfterValidator, BaseModel, ConfigDict, Field
from pydantic.alias_generators import to_camel


def _keycode(name: str) -> str:
    if name not in ecodes.ecodes or not name.startswith(("KEY_", "BTN_")):
        msg = f"not an evdev key name: {name}"
        raise ValueError(msg)
    return name


def _usb_id(value: str) -> str:
    if len(value) != 4 or any(c not in "0123456789abcdef" for c in value):
        msg = f"not four lowercase hex digits: {value}"
        raise ValueError(msg)
    return value


KeyName = Annotated[str, AfterValidator(_keycode)]
UsbIdPart = Annotated[str, AfterValidator(_usb_id)]


def code(name: str) -> int:
    return ecodes.ecodes[name]


class Model(BaseModel):
    model_config = ConfigDict(
        frozen=True, extra="forbid", alias_generator=to_camel, validate_by_name=True
    )


class UsbDevice(Model):
    vendor: UsbIdPart
    product: UsbIdPart

    @property
    def label(self) -> str:
        return f"{self.vendor}:{self.product}"


class Match(UsbDevice):
    """One event node of a USB device: a receiver exposes several with one name."""

    keys: list[KeyName] = Field(
        default_factory=list, description="Keys the node must report"
    )


class Tap(Model):
    do: Literal["tap"] = "tap"
    key: KeyName
    sound: bool = False


class VmStart(Model):
    do: Literal["vm-start"] = "vm-start"


class VmStop(Model):
    do: Literal["vm-stop"] = "vm-stop"


class UsbAttach(Model):
    do: Literal["usb-attach"] = "usb-attach"


class UsbDetach(Model):
    do: Literal["usb-detach"] = "usb-detach"


class Guest(Model):
    """The forwarded devices and the vmUsb devices to the VM."""

    do: Literal["guest"] = "guest"


class Host(Model):
    """Both back to the host."""

    do: Literal["host"] = "host"


class Vcp(Model):
    do: Literal["vcp"] = "vcp"
    model: str
    feature: str
    value: str


class Brightness(Model):
    do: Literal["brightness"] = "brightness"
    delta: int


class Volume(Model):
    do: Literal["volume"] = "volume"
    up: bool


Action = Annotated[
    Tap
    | VmStart
    | VmStop
    | UsbAttach
    | UsbDetach
    | Guest
    | Host
    | Vcp
    | Brightness
    | Volume,
    Field(discriminator="do"),
]


class Binding(Model):
    """`action` runs when `key` is released, if `hold` is down then (or no key is, without `hold`)."""

    key: KeyName
    hold: KeyName | None = None
    action: Action


class BrightnessPair(Model):
    """Two monitors set together: `follower` is `primary` plus `offset`."""

    primary: str
    follower: str
    offset: int = 0


class Config(Model):
    numpad: Match
    bindings: list[Binding]
    domain: str
    libvirt_uri: str = "qemu:///system"
    vm_usb: list[UsbDevice] = Field(default_factory=list)
    # Keyboards and mice that reach the VM through an evdev input, not USB.
    forward: list[Match] = Field(default_factory=list)
    brightness: BrightnessPair | None = None
    sound: Path | None = None

    @classmethod
    def load(cls, path: Path) -> Config:
        return cls.model_validate_json(path.read_bytes())
