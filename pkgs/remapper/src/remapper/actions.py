"""What a binding does: libvirt, DDC/CI, PipeWire and the output keyboard."""

from __future__ import annotations

import logging
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Final, Protocol

import anyio
from evdev import KeyEvent, ecodes

from .config import (
    Brightness,
    Tap,
    UsbAttach,
    UsbDetach,
    Vcp,
    VmStart,
    VmStop,
    Volume,
    code,
)

if TYPE_CHECKING:
    from collections.abc import Sequence

    from .config import Action, Config, UsbDevice

log = logging.getLogger(__name__)

# ddcutil takes 1-3 s per command on these monitors; virsh attach waits on QEMU.
TIMEOUT: Final = 20
BRIGHTNESS: Final = "0x10"
USB_DEVICES: Final = Path("/sys/bus/usb/devices")


class Runner(Protocol):
    async def __call__(
        self, argv: Sequence[str], stdin: bytes | None = None
    ) -> str | None: ...


class Keyboard(Protocol):
    def write(self, etype: int, code: int, value: int) -> None: ...
    def syn(self) -> None: ...


async def run(argv: Sequence[str], stdin: bytes | None = None) -> str | None:
    """stdout of a command that succeeded; None, logged, for one that failed."""
    try:
        with anyio.fail_after(TIMEOUT):
            done = await anyio.run_process(
                argv, input=stdin, check=False, stderr=subprocess.PIPE
            )
    except (OSError, TimeoutError) as e:
        log.warning("%s: %s", argv[0], e)
        return None
    if done.returncode != 0:
        log.warning(
            "%s failed (%d): %s",
            " ".join(argv),
            done.returncode,
            done.stderr.decode().strip(),
        )
        return None
    return done.stdout.decode()


def hostdev(device: UsbDevice) -> bytes:
    return (
        '<hostdev mode="subsystem" type="usb" managed="yes"><source>'
        f'<vendor id="0x{device.vendor}"/><product id="0x{device.product}"/>'
        "</source></hostdev>"
    ).encode()


def plugged(root: Path = USB_DEVICES) -> set[tuple[str, str]]:
    """(vendor, product) of every USB device the host has now."""
    found: set[tuple[str, str]] = set()
    for dev in root.iterdir():
        try:
            found.add(
                (
                    (dev / "idVendor").read_text().strip(),
                    (dev / "idProduct").read_text().strip(),
                )
            )
        except FileNotFoundError:
            continue
    return found


def parse_vcp(brief: str) -> tuple[int, int]:
    """(current, max) from `ddcutil getvcp --brief`, which prints `VCP 10 C 50 100`."""
    for line in brief.splitlines():
        parts = line.split()
        if parts[:1] == ["VCP"] and len(parts) >= 5 and parts[2] == "C":
            return int(parts[3]), int(parts[4])
    msg = f"no continuous VCP value in {brief!r}"
    raise ValueError(msg)


def parse_volume(out: str) -> float:
    """The level from `wpctl get-volume`, which prints `Volume: 0.40` (and ` [MUTED]`)."""
    return float(out.split()[1])


def sound_volume(system: float) -> float:
    """Loud enough to hear at a low system volume, not deafening at a high one."""
    return 0.1 / max(system / 2, 0.1)


@dataclass
class Actions:
    config: Config
    # None when no binding taps a key.
    keyboard: Keyboard | None
    run: Runner = run
    usb_root: Path = USB_DEVICES
    # One libvirt change at a time: an attach racing a detach leaves either.
    vm_lock: anyio.Lock = field(default_factory=anyio.Lock)
    # ddcutil commands on one I2C bus interleave badly.
    ddc_lock: anyio.Lock = field(default_factory=anyio.Lock)

    async def __call__(self, action: Action) -> None:
        log.info("%s", action.do)
        match action:
            case Tap():
                self.tap(code(action.key))
                if action.sound:
                    await self.play()
            case VmStart():
                async with self.vm_lock:
                    await self.virsh("start", self.config.domain)
            case VmStop():
                async with self.vm_lock:
                    await self.virsh("destroy", "--graceful", self.config.domain)
            case UsbAttach():
                await self.usb(attach=True)
            case UsbDetach():
                await self.usb(attach=False)
            case Vcp():
                async with self.ddc_lock:
                    await self.run(
                        [
                            "ddcutil",
                            "--model",
                            action.model,
                            "setvcp",
                            action.feature,
                            action.value,
                        ]
                    )
            case Brightness():
                await self.brightness(action.delta)
            case Volume():
                await self.run(["volumectl", "+" if action.up else "-"])

    def tap(self, key: int) -> None:
        if self.keyboard is None:
            return
        for value in (KeyEvent.key_down, KeyEvent.key_up):
            self.keyboard.write(ecodes.EV_KEY, key, value)
            self.keyboard.syn()

    async def play(self) -> None:
        if self.config.sound is None:
            return
        out = await self.run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"])
        volume = sound_volume(parse_volume(out)) if out else 0.1
        await self.run(["pw-play", f"--volume={volume:.2f}", str(self.config.sound)])

    async def virsh(self, *args: str, stdin: bytes | None = None) -> str | None:
        return await self.run(
            ["virsh", "--connect", self.config.libvirt_uri, *args], stdin
        )

    async def usb(self, *, attach: bool) -> None:
        verb = "attach-device" if attach else "detach-device"
        here = plugged(self.usb_root) if attach else None
        async with self.vm_lock:
            for device in self.config.vm_usb:
                # A device the host lacks would only add a libvirt error to the log.
                if here is not None and (device.vendor, device.product) not in here:
                    log.info("%s: not plugged in", device.label)
                    continue
                await self.virsh(
                    verb,
                    self.config.domain,
                    "/dev/stdin",
                    "--live",
                    stdin=hostdev(device),
                )

    async def brightness(self, delta: int) -> None:
        pair = self.config.brightness
        if pair is None:
            return
        async with self.ddc_lock:
            out = await self.run(
                ["ddcutil", "--model", pair.primary, "getvcp", BRIGHTNESS, "--brief"]
            )
            if out is None:
                return
            current, top = parse_vcp(out)
            level = max(0, min(current + delta, top))
            await self.run(
                ["ddcutil", "--model", pair.primary, "setvcp", BRIGHTNESS, str(level)]
            )
            await self.run(
                [
                    "ddcutil",
                    "--model",
                    pair.follower,
                    "setvcp",
                    BRIGHTNESS,
                    str(min(level + pair.offset, 100)),
                ]
            )
