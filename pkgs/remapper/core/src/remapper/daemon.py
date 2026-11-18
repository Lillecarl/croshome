"""A numpad as a remote control. Plugins say what its keys do."""

from __future__ import annotations

import argparse
import contextlib
import logging
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Protocol

import anyio
from evdev import KeyEvent, UInput, ecodes

from .chord import Chords
from .config import ConfigError, Tap, action_name, code, parse
from .inputs import grab, read, watch
from .plugin import installed

if TYPE_CHECKING:
    from collections.abc import Mapping

    from evdev import InputDevice, InputEvent

    from .config import Action, Config
    from .plugin import Plugin

log = logging.getLogger(__name__)


class Keyboard(Protocol):
    def write(self, etype: int, code: int, value: int) -> None: ...
    def syn(self) -> None: ...


def tap(keyboard: Keyboard | None, key: int) -> None:
    if keyboard is None:
        return
    for value in (KeyEvent.key_down, KeyEvent.key_up):
        keyboard.write(ecodes.EV_KEY, key, value)
        keyboard.syn()


def handlers(plugins: Mapping[str, Plugin]) -> dict[str, Plugin]:
    """The plugin that does each action, by action name."""
    return {
        action_name(model): plugin
        for plugin in plugins.values()
        for model in plugin.actions
    }


async def serve(
    config: Config, plugins: Mapping[str, Plugin], keyboard: Keyboard | None
) -> None:
    """Start `plugins`, then turn numpad releases into their actions. Never returns."""
    owner = handlers(plugins)

    async def perform(actions: tuple[Action, ...]) -> None:
        for action in actions:
            log.info("%s", action.do)
            try:
                if isinstance(action, Tap):
                    tap(keyboard, code(action.key))
                else:
                    await owner[action.do](action)
            except Exception:
                # One action failing (a monitor off, the VM gone) must not
                # stop the numpad. The rest of the list may depend on it.
                log.exception("%s failed", action.do)
                return

    async with anyio.create_task_group() as tg:
        for plugin in plugins.values():
            await tg.start(plugin.serve)

        async def numpad(dev: InputDevice) -> None:
            chords = Chords.of(config.bindings)

            def handle(event: InputEvent) -> None:
                if event.type == ecodes.EV_KEY and (
                    actions := chords.feed(event.code, event.value)
                ):
                    tg.start_soon(perform, actions)

            await grab(dev)
            await read(dev, handle)

        await watch([config.numpad], numpad)


def output_keys(config: Config) -> list[int]:
    return sorted(
        {code(a.key) for b in config.bindings for a in b.actions if isinstance(a, Tap)}
    )


async def main(config: Config, available: Mapping[str, type[Plugin]]) -> None:
    plugins = {
        name: available[name](settings) for name, settings in config.plugins.items()
    }
    # Created once: it outlives every numpad node, so a replug never removes it.
    with contextlib.ExitStack() as stack:
        keys = output_keys(config)
        keyboard = (
            stack.enter_context(UInput({ecodes.EV_KEY: keys}, name="remapper"))
            if keys
            else None
        )
        await serve(config, plugins, keyboard)


def cli() -> None:
    parser = argparse.ArgumentParser(prog="remapper", description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="log grabs and actions"
    )
    parser.add_argument(
        "--check", action="store_true", help="validate the configuration and exit"
    )
    args = parser.parse_args()
    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(name)s: %(message)s",
    )
    available = installed()
    try:
        config = parse(args.config.read_bytes(), available)
    except ConfigError as e:
        sys.exit(f"{args.config}: {e}")
    if not args.check:
        anyio.run(main, config, available)
