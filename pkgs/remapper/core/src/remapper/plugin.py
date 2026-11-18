"""What a plugin is, and which ones are installed."""

from __future__ import annotations

from abc import ABC, abstractmethod
from importlib.metadata import entry_points
from typing import TYPE_CHECKING, ClassVar, Final

import anyio

from .process import run

if TYPE_CHECKING:
    from anyio.abc import TaskStatus

    from .config import Action, Model
    from .process import Runner

GROUP: Final = "remapper.plugins"


class Plugin[S: Model](ABC):
    """A set of actions, the settings they share, and the work behind them.

    A distribution registers its subclass under the entry point group
    `remapper.plugins`. The entry point's name is the plugin's key under
    `plugins` in the configuration file, and only a plugin named there is
    started. Nix decides which distributions are installed; nothing is
    loaded from anywhere else.
    """

    Settings: ClassVar[type[Model]]
    actions: ClassVar[tuple[type[Action], ...]]

    def __init__(self, settings: S, run: Runner = run) -> None:
        self.settings = settings
        self.run = run

    async def serve(
        self, *, task_status: TaskStatus[None] = anyio.TASK_STATUS_IGNORED
    ) -> None:
        """Run for the daemon's lifetime. Call `task_status.started()` once actions may run."""
        task_status.started()

    @abstractmethod
    async def __call__(self, action: Action) -> None:
        """Do `action`, one of `actions`. Raise only for a bug: the daemon logs it and goes on."""


def installed() -> dict[str, type[Plugin]]:
    found: dict[str, type[Plugin]] = {}
    for entry in entry_points(group=GROUP):
        plugin = entry.load()
        if not (isinstance(plugin, type) and issubclass(plugin, Plugin)):
            msg = f"entry point {entry.name} ({entry.value}) is not a Plugin"
            raise TypeError(msg)
        found[entry.name] = plugin
    return found
