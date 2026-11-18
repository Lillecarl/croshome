from __future__ import annotations

from pathlib import Path

import anyio
import pytest
from remapper.testing import Recorder
from remapper_audio import Audio, AudioSettings, Sound, Volume, sound_volume


def test_sound_volume() -> None:
    assert sound_volume(0.0) == pytest.approx(1.0)
    assert sound_volume(1.0) == pytest.approx(0.2)


def test_sound_plays_louder_when_the_system_is_quiet() -> None:
    runner = Recorder({"wpctl get-volume @DEFAULT_AUDIO_SINK@": "Volume: 0.10\n"})
    anyio.run(Audio(AudioSettings(), runner), Sound(file=Path("/x.mp3")))
    assert runner.calls[1] == ["pw-play", "--volume=1.00", "/x.mp3"]


def test_volume() -> None:
    runner = Recorder()
    anyio.run(Audio(AudioSettings(), runner), Volume(up=False))
    assert runner.calls == [["volumectl", "-"]]
