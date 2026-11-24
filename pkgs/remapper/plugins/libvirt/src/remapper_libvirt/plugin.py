"""A libvirt VM: start and stop it, pass USB devices through, route input into it."""

from __future__ import annotations

import contextlib
import logging
import os
from pathlib import Path
from typing import TYPE_CHECKING, ClassVar, Final

import anyio
from anyio.streams.buffered import BufferedByteReceiveStream
from evdev import UInput, ecodes
from remapper.inputs import read, watch
from remapper.plugin import Plugin
from remapper.process import run

from .config import Guest, Host, LibvirtSettings, UsbAttach, UsbDetach, VmStart, VmStop
from .route import GUEST_KEYS, GUEST_NAME, GUEST_RELS, HOST_NAME, Router
from .vm import hostdev, plan, stopped

if TYPE_CHECKING:
    from anyio.abc import TaskStatus
    from evdev import InputDevice
    from remapper.config import Action
    from remapper.process import Runner

    from .route import Writer

log = logging.getLogger(__name__)

USB_DEVICES: Final = Path("/sys/bus/usb/devices")
# libvirtd restarted, or the domain is not defined yet.
EVENTS_RETRY: Final = 5


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


class Libvirt(Plugin[LibvirtSettings]):
    Settings: ClassVar = LibvirtSettings
    actions: ClassVar = (VmStart, VmStop, UsbAttach, UsbDetach, Guest, Host)

    def __init__(
        self,
        settings: LibvirtSettings,
        run: Runner = run,
        *,
        guest: tuple[Writer, str] | None = None,
        follow: bool = True,
        usb_root: Path = USB_DEVICES,
    ) -> None:
        """`guest` is the device the VM reads and its path; by default a new uinput device."""
        super().__init__(settings, run)
        self.guest = guest
        self.follow = follow
        self.usb_root = usb_root
        # None until serve() has the guest device, and when nothing is forwarded.
        self.router: Router | None = None
        # One libvirt change at a time: an attach racing a detach leaves either.
        self.vm_lock = anyio.Lock()

    async def serve(
        self, *, task_status: TaskStatus[None] = anyio.TASK_STATUS_IGNORED
    ) -> None:
        if not self.settings.forward:
            task_status.started()
            return
        with contextlib.ExitStack() as stack:
            guest = self.guest or new_guest(stack)
            remap = new_host if self.settings.caps_as_ctrl_esc else None
            router = self.router = Router(*guest, remap)

            async def forwarded(dev: InputDevice) -> None:
                if remap is not None:
                    await all_up(dev)
                node = router.add(dev)
                try:
                    await read(dev, lambda event: router.handle(event, node))
                finally:
                    router.remove(node)

            async with anyio.create_task_group() as tg:
                tg.start_soon(watch, self.settings.forward, forwarded)
                if self.follow:
                    tg.start_soon(self.follow_vm, router)
                task_status.started()

    async def __call__(self, action: Action) -> None:
        domain = self.settings.domain
        match action:
            case VmStart():
                async with self.vm_lock:
                    await self.virsh("start", domain)
            case VmStop():
                async with self.vm_lock:
                    await self.virsh("destroy", "--graceful", domain)
            case UsbAttach():
                await self.usb(attach=True)
            case UsbDetach():
                await self.usb(attach=False)
            case Guest():
                if self.router is not None:
                    async with self.vm_lock:
                        if not await self.attach_input(self.router.path):
                            return
                    self.router.to_guest()
                await self.usb(attach=True)
            case Host():
                if self.router is not None:
                    self.router.to_host()
                await self.usb(attach=False)

    async def virsh(self, *args: str, stdin: bytes | None = None) -> str | None:
        return await self.run(
            ["virsh", "--connect", self.settings.libvirt_uri, *args], stdin
        )

    async def attach_input(self, path: str) -> bool:
        """Whether the VM reads `path` now, through our USB keyboard and mouse."""
        domain = self.settings.domain
        xml = await self.virsh("dumpxml", domain)
        if xml is None:
            return False
        detach, attach = plan(xml, path, self.settings.usb_hid)
        for old in detach:
            await self.virsh("detach-device", domain, "/dev/stdin", "--live", stdin=old)
        for new in attach:
            if (
                await self.virsh(
                    "attach-device", domain, "/dev/stdin", "--live", stdin=new
                )
                is None
            ):
                return False
        return True

    async def usb(self, *, attach: bool) -> None:
        if not self.settings.vm_usb:
            return
        verb = "attach-device" if attach else "detach-device"
        here = plugged(self.usb_root) if attach else None
        async with self.vm_lock:
            for device in self.settings.vm_usb:
                # A device the host lacks would only add a libvirt error to the log.
                if here is not None and (device.vendor, device.product) not in here:
                    log.info("%s: not plugged in", device.label)
                    continue
                await self.virsh(
                    verb,
                    self.settings.domain,
                    "/dev/stdin",
                    "--live",
                    stdin=hostdev(device),
                )

    async def follow_vm(self, router: Router) -> None:
        """Route input back to the host when the VM stops, so it is never lost there."""
        argv = [
            "virsh",
            "--connect",
            self.settings.libvirt_uri,
            "event",
            "--domain",
            self.settings.domain,
            "--event",
            "lifecycle",
            "--loop",
        ]
        # virsh translates the event names.
        env = {**os.environ, "LC_ALL": "C"}
        while True:
            try:
                async with await anyio.open_process(argv, env=env, stderr=None) as proc:
                    if proc.stdout is None:
                        return
                    lines = BufferedByteReceiveStream(proc.stdout)
                    while True:
                        line = (await lines.receive_until(b"\n", 4096)).decode()
                        if stopped(line):
                            router.to_host()
            except (anyio.EndOfStream, anyio.IncompleteRead, OSError) as e:
                log.warning("virsh event: %s", e or "exited")
            # Nothing announces that libvirtd is back.
            await anyio.sleep(EVENTS_RETRY)


async def all_up(dev: InputDevice) -> None:
    """Until no key of `dev` is down: after a grab the host would never see it go up."""
    while dev.active_keys():
        await anyio.wait_readable(dev.fd)
        with contextlib.suppress(BlockingIOError):
            for _ in dev.read():
                pass


def new_host(dev: InputDevice) -> UInput:
    """The device the host reads instead of `dev`.

    With no vendor and product of `dev`: a copy of those matches `forward`.
    """
    capabilities = dev.capabilities()
    keys = set(capabilities.get(ecodes.EV_KEY, []))
    if ecodes.KEY_CAPSLOCK in keys:
        keys |= {ecodes.KEY_LEFTCTRL, ecodes.KEY_ESC}
    events = {ecodes.EV_KEY: sorted(keys)}
    if rels := capabilities.get(ecodes.EV_REL):
        events[ecodes.EV_REL] = rels
    return UInput(events, name=HOST_NAME)


def new_guest(stack: contextlib.ExitStack) -> tuple[Writer, str]:
    device = stack.enter_context(
        UInput(
            {ecodes.EV_KEY: GUEST_KEYS, ecodes.EV_REL: GUEST_RELS},
            name=GUEST_NAME,
        )
    )
    if device.device is None:
        msg = "uinput made no event node for the guest device"
        raise RuntimeError(msg)
    return device, device.device.path
