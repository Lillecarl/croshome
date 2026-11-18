"""DDC/CI monitors through ddcutil: any VCP feature, and brightness kept in step."""

from __future__ import annotations

from typing import TYPE_CHECKING, ClassVar, Final, Literal

import anyio
from remapper.config import Action, Model
from remapper.plugin import Plugin
from remapper.process import run

if TYPE_CHECKING:
    from remapper.process import Runner

BRIGHTNESS: Final = "0x10"


class BrightnessPair(Model):
    """Two monitors set together: `follower` is `primary` plus `offset`."""

    primary: str
    follower: str
    offset: int = 0


class DdcSettings(Model):
    brightness: BrightnessPair | None = None


class Vcp(Action):
    do: Literal["vcp"] = "vcp"
    model: str
    feature: str
    value: str


class Brightness(Action):
    do: Literal["brightness"] = "brightness"
    delta: int


def parse_vcp(brief: str) -> tuple[int, int]:
    """(current, max) from `ddcutil getvcp --brief`, which prints `VCP 10 C 50 100`."""
    for line in brief.splitlines():
        parts = line.split()
        if parts[:1] == ["VCP"] and len(parts) >= 5 and parts[2] == "C":
            return int(parts[3]), int(parts[4])
    msg = f"no continuous VCP value in {brief!r}"
    raise ValueError(msg)


class Ddc(Plugin[DdcSettings]):
    Settings: ClassVar = DdcSettings
    actions: ClassVar = (Vcp, Brightness)

    def __init__(self, settings: DdcSettings, run: Runner = run) -> None:
        super().__init__(settings, run)
        # ddcutil commands on one I2C bus interleave badly.
        self.lock = anyio.Lock()

    async def __call__(self, action: Action) -> None:
        match action:
            case Vcp():
                async with self.lock:
                    await self.setvcp(action.model, action.feature, action.value)
            case Brightness():
                await self.brightness(action.delta)

    async def setvcp(self, model: str, feature: str, value: str) -> None:
        await self.run(["ddcutil", "--model", model, "setvcp", feature, value])

    async def brightness(self, delta: int) -> None:
        pair = self.settings.brightness
        if pair is None:
            return
        async with self.lock:
            out = await self.run(
                ["ddcutil", "--model", pair.primary, "getvcp", BRIGHTNESS, "--brief"]
            )
            if out is None:
                return
            current, top = parse_vcp(out)
            level = max(0, min(current + delta, top))
            await self.setvcp(pair.primary, BRIGHTNESS, str(level))
            await self.setvcp(
                pair.follower, BRIGHTNESS, str(min(level + pair.offset, 100))
            )
