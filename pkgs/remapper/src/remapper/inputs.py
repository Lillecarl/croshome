"""Grab every event node that matches, each time it appears."""

from __future__ import annotations

import errno
import logging
from typing import TYPE_CHECKING, Final

import anyio
import pyudev
from evdev import InputDevice, ecodes

from .config import code

if TYPE_CHECKING:
    from collections.abc import Awaitable, Callable

    from evdev import InputEvent

    from .config import Match

log = logging.getLogger(__name__)

GRAB_RETRY: Final = 0.5


def matches(dev: InputDevice, match: Match) -> bool:
    if (f"{dev.info.vendor:04x}", f"{dev.info.product:04x}") != (
        match.vendor,
        match.product,
    ):
        return False
    keys = set(dev.capabilities().get(ecodes.EV_KEY, []))
    return all(code(k) in keys for k in match.keys)


def open_matching(node: str, match: Match) -> InputDevice | None:
    try:
        dev = InputDevice(node)
    except OSError:
        # Gone again already, or a node this user may not read.
        return None
    if matches(dev, match):
        return dev
    dev.close()
    return None


async def grab(dev: InputDevice) -> None:
    """Grab the node, waiting out another holder: a remapper still stopping, say."""
    warned = False
    while True:
        try:
            dev.grab()
        except OSError as e:
            if e.errno != errno.EBUSY:
                raise
            if not warned:
                log.warning("%s is grabbed elsewhere; retrying", dev.path)
                warned = True
            # EVIOCGRAB has no notification when the holder lets go.
            await anyio.sleep(GRAB_RETRY)
        else:
            return


async def read_grabbed(dev: InputDevice, handle: Callable[[InputEvent], None]) -> None:
    """Hand each of the node's events to `handle`, grabbed, until it is unplugged."""
    await grab(dev)
    while True:
        await anyio.wait_readable(dev.fd)
        try:
            batch = list(dev.read())
        except BlockingIOError:
            continue
        except OSError as e:
            if e.errno == errno.ENODEV:
                return
            raise
        for event in batch:
            handle(event)


async def watch(match: Match, serve: Callable[[InputDevice], Awaitable[None]]) -> None:
    """Run `serve` on each matching node while it exists. Never returns."""
    context = pyudev.Context()
    monitor = pyudev.Monitor.from_netlink(context)
    monitor.filter_by("input")
    # Listen before listing, so a node added in between is not missed.
    monitor.start()
    served: dict[str, anyio.CancelScope] = {}

    async def guard(dev: InputDevice, scope: anyio.CancelScope) -> None:
        path = dev.path
        with scope:
            try:
                log.info("grabbed %s: %s", path, dev.name)
                await serve(dev)
            except OSError as e:
                log.warning("%s: %s", path, e)
            finally:
                dev.close()
                if served.get(path) is scope:
                    del served[path]
                log.info("released %s", path)

    async with anyio.create_task_group() as tg:

        def offer(node: str | None) -> None:
            if (
                node is None
                or not node.startswith("/dev/input/event")
                or node in served
            ):
                return
            dev = open_matching(node, match)
            if dev is not None:
                served[node] = anyio.CancelScope()
                tg.start_soon(guard, dev, served[node])

        for device in context.list_devices(subsystem="input"):
            offer(device.device_node)
        while True:
            await anyio.wait_readable(monitor.fileno())
            while (device := monitor.poll(timeout=0)) is not None:
                node = device.device_node
                if device.action == "add":
                    offer(node)
                elif device.action == "remove" and node in served:
                    # A new node can reuse the path before the old read sees ENODEV.
                    served.pop(node).cancel()
