from __future__ import annotations

import anyio
import pytest
from remapper.testing import Recorder
from remapper_ddc import Brightness, Ddc, DdcSettings, Vcp, parse_vcp

SETTINGS = DdcSettings.model_validate(
    {"brightness": {"primary": "A", "follower": "B", "offset": 25}}
)


def test_parse_vcp() -> None:
    assert parse_vcp("VCP 10 C 50 100\n") == (50, 100)
    with pytest.raises(ValueError, match="no continuous"):
        parse_vcp("VCP 60 SNC x0f\n")


def test_brightness_clamps_and_offsets() -> None:
    runner = Recorder({"ddcutil --model A getvcp 0x10 --brief": "VCP 10 C 95 100\n"})
    anyio.run(Ddc(SETTINGS, runner), Brightness(delta=10))
    assert runner.calls[1:] == [
        ["ddcutil", "--model", "A", "setvcp", "0x10", "100"],
        ["ddcutil", "--model", "B", "setvcp", "0x10", "100"],
    ]


def test_vcp() -> None:
    runner = Recorder()
    anyio.run(Ddc(DdcSettings(), runner), Vcp(model="M", feature="0x60", value="0x11"))
    assert runner.calls == [["ddcutil", "--model", "M", "setvcp", "0x60", "0x11"]]
