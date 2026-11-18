"""PipeWire: the volume through avizo's volumectl, and a sound through pw-play."""

from __future__ import annotations

from pathlib import Path  # noqa: TC003 -- pydantic resolves it at runtime
from typing import ClassVar, Literal

from remapper.config import Action, Model
from remapper.plugin import Plugin


class AudioSettings(Model):
    pass


class Volume(Action):
    do: Literal["volume"] = "volume"
    up: bool


class Sound(Action):
    do: Literal["sound"] = "sound"
    file: Path


def parse_volume(out: str) -> float:
    """The level from `wpctl get-volume`, which prints `Volume: 0.40` (and ` [MUTED]`)."""
    return float(out.split()[1])


def sound_volume(system: float) -> float:
    """Loud enough to hear at a low system volume, not deafening at a high one."""
    return 0.1 / max(system / 2, 0.1)


class Audio(Plugin[AudioSettings]):
    Settings: ClassVar = AudioSettings
    actions: ClassVar = (Volume, Sound)

    async def __call__(self, action: Action) -> None:
        match action:
            case Volume():
                await self.run(["volumectl", "+" if action.up else "-"])
            case Sound():
                out = await self.run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"])
                volume = sound_volume(parse_volume(out)) if out else 0.1
                await self.run(["pw-play", f"--volume={volume:.2f}", str(action.file)])
