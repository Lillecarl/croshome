"""The numpad as a remote control for the host, the VM and the monitors."""

from __future__ import annotations

import argparse
import logging
from pathlib import Path
from typing import TYPE_CHECKING

import anyio
from evdev import UInput, ecodes

from .actions import Actions, Keyboard, Runner, run
from .chord import Chords
from .config import Config, Tap, code
from .inputs import read_grabbed, watch

if TYPE_CHECKING:
    from evdev import InputDevice, InputEvent

    from .config import Action

log = logging.getLogger(__name__)


async def serve(
    config: Config, keyboard: Keyboard | None, runner: Runner = run
) -> None:
    actions = Actions(config, keyboard, runner)

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

            await read_grabbed(dev, handle)

        await watch(config.numpad, numpad)


def output_keys(config: Config) -> list[int]:
    return sorted(
        {code(b.action.key) for b in config.bindings if isinstance(b.action, Tap)}
    )


async def main(config: Config) -> None:
    keys = output_keys(config)
    if not keys:
        await serve(config, None)
        return
    # Created once: it outlives every numpad node, so a replug never removes it.
    with UInput({ecodes.EV_KEY: keys}, name="remapper") as keyboard:
        await serve(config, keyboard)


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
