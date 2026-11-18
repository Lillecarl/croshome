"""The numpad as a remote control for the host, the VM and the monitors."""

from __future__ import annotations

import argparse
import contextlib
import logging
import os
from pathlib import Path
from typing import TYPE_CHECKING, Final

import anyio
from anyio.streams.buffered import BufferedByteReceiveStream
from evdev import UInput, ecodes

from .actions import Actions, Keyboard, Runner, run
from .chord import Chords
from .config import Config, Tap, code
from .inputs import grab, read, watch
from .route import GUEST_KEYS, GUEST_NAME, GUEST_RELS, Router, Writer
from .vm import stopped

if TYPE_CHECKING:
    from evdev import InputDevice, InputEvent

    from .config import Action

log = logging.getLogger(__name__)

# libvirtd restarted, or the domain is not defined yet.
EVENTS_RETRY: Final = 5


async def follow_vm(config: Config, router: Router) -> None:
    """Route input back to the host when the VM stops, so it is never lost there."""
    argv = [
        "virsh",
        "--connect",
        config.libvirt_uri,
        "event",
        "--domain",
        config.domain,
    ]
    argv += ["--event", "lifecycle", "--loop"]
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


async def serve(
    config: Config,
    keyboard: Keyboard | None,
    runner: Runner = run,
    guest: tuple[Writer, str] | None = None,
    *,
    follow: bool = True,
) -> None:
    """`guest` is the device the VM reads and its path, when `config.forward` lists any."""
    router = Router(*guest) if guest is not None else None
    actions = Actions(config, keyboard, runner, router=router)

    async def perform(action: Action) -> None:
        try:
            await actions(action)
        except Exception:
            # One action failing (a monitor off, the VM gone) must not stop the numpad.
            log.exception("%s failed", action.do)

    async with anyio.create_task_group() as tg:

        async def numpad(dev: InputDevice) -> None:
            chords = Chords.of(config.bindings)

            def handle(event: InputEvent) -> None:
                if event.type == ecodes.EV_KEY and (
                    action := chords.feed(event.code, event.value)
                ):
                    tg.start_soon(perform, action)

            await grab(dev)
            await read(dev, handle)

        if router is not None:

            async def forwarded(dev: InputDevice) -> None:
                router.add(dev)
                try:
                    await read(dev, router.handle)
                finally:
                    router.remove(dev)

            tg.start_soon(watch, config.forward, forwarded)
            if follow:
                tg.start_soon(follow_vm, config, router)
        await watch([config.numpad], numpad)


def output_keys(config: Config) -> list[int]:
    return sorted(
        {code(b.action.key) for b in config.bindings if isinstance(b.action, Tap)}
    )


async def main(config: Config) -> None:
    # Created once: they outlive every input node, so a replug never removes them.
    with contextlib.ExitStack() as stack:
        keys = output_keys(config)
        keyboard = (
            stack.enter_context(UInput({ecodes.EV_KEY: keys}, name="remapper"))
            if keys
            else None
        )
        guest = None
        if config.forward:
            device = stack.enter_context(
                UInput(
                    {ecodes.EV_KEY: GUEST_KEYS, ecodes.EV_REL: GUEST_RELS},
                    name=GUEST_NAME,
                )
            )
            if device.device is None:
                msg = "uinput made no event node for the guest device"
                raise RuntimeError(msg)
            guest = (device, device.device.path)
        await serve(config, keyboard, guest=guest)


def cli() -> None:
    parser = argparse.ArgumentParser(prog="remapper", description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="log grabs and actions"
    )
    args = parser.parse_args()
    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(name)s: %(message)s",
    )
    anyio.run(main, Config.load(args.config))
