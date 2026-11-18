from __future__ import annotations

import json
from typing import TYPE_CHECKING, Literal

import pytest
from evdev import ecodes
from remapper.chord import Chords
from remapper.config import Action, ConfigError, Model, Tap, parse
from remapper.daemon import handlers
from remapper.plugin import Plugin

if TYPE_CHECKING:
    from remapper.config import Config

DOWN, UP, HOLD = 1, 0, 2
KP0, KP1, KP2 = ecodes.KEY_KP0, ecodes.KEY_KP1, ecodes.KEY_KP2


class LampSettings(Model):
    room: str


class On(Action):
    do: Literal["on"] = "on"


class Dim(Action):
    do: Literal["dim"] = "dim"
    by: int


class Lamp(Plugin[LampSettings]):
    Settings = LampSettings
    actions = (On, Dim)

    async def __call__(self, action: Action) -> None:
        pass


class Clash(Lamp):
    actions = (On,)


INSTALLED: dict[str, type[Plugin]] = {"lamp": Lamp}
CONFIG = {
    "numpad": {"vendor": "062a", "product": "4101", "keys": ["KEY_KP0"]},
    "plugins": {"lamp": {"room": "hall"}},
    "bindings": [
        {"key": "KEY_KP0", "actions": [{"do": "tap", "key": "KEY_SPACE"}]},
        {"key": "KEY_KP1", "hold": "KEY_KP0", "actions": [{"do": "on"}]},
        {"key": "KEY_KP1", "actions": [{"do": "dim", "by": 10}, {"do": "on"}]},
    ],
}


def load(data: object, installed: dict[str, type[Plugin]] = INSTALLED) -> Config:
    return parse(json.dumps(data), installed)


def press(chords: Chords, *steps: tuple[int, int]) -> list[str]:
    return [a.do for key, value in steps for a in chords.feed(key, value)]


def test_bindings_carry_plugin_actions_in_order() -> None:
    config = load(CONFIG)
    assert [tuple(type(a) for a in b.actions) for b in config.bindings] == [
        (Tap,),
        (On,),
        (Dim, On),
    ]
    assert config.bindings[1].hold == KP0
    assert config.plugins == {"lamp": LampSettings(room="hall")}


def test_tap_fires_on_release() -> None:
    chords = Chords.of(load(CONFIG).bindings)
    assert press(chords, (KP1, DOWN), (KP1, HOLD), (KP1, UP)) == ["dim", "on"]


def test_modifier_picks_its_binding_and_does_not_tap() -> None:
    chords = Chords.of(load(CONFIG).bindings)
    steps = [(KP0, DOWN), (KP1, DOWN), (KP1, UP), (KP0, UP)]
    assert press(chords, *steps) == ["on"]


def test_modifier_alone_is_a_tap() -> None:
    chords = Chords.of(load(CONFIG).bindings)
    assert press(chords, (KP0, DOWN), (KP0, UP)) == ["tap"]


def test_modifier_without_binding_fires_nothing() -> None:
    chords = Chords.of(load(CONFIG).bindings)
    assert press(chords, (KP0, DOWN), (KP2, DOWN), (KP2, UP), (KP0, UP)) == []


def test_release_without_press_after_reset() -> None:
    chords = Chords.of(load(CONFIG).bindings)
    chords.feed(KP0, DOWN)
    chords.reset()
    assert press(chords, (KP0, UP), (KP1, DOWN), (KP1, UP)) == ["dim", "on"]


def test_rejects_unknown_key() -> None:
    bad = {**CONFIG, "bindings": [{"key": "KEY_NOPE", "actions": [{"do": "on"}]}]}
    with pytest.raises(ConfigError, match="KEY_NOPE"):
        load(bad)


def test_rejects_a_plugin_that_is_not_installed() -> None:
    with pytest.raises(ConfigError, match="no plugin named vm; installed: lamp"):
        load({**CONFIG, "plugins": {"vm": {}}})


def test_rejects_bad_plugin_settings() -> None:
    with pytest.raises(ConfigError, match=r"plugins\.lamp"):
        load({**CONFIG, "plugins": {"lamp": {"rooms": "hall"}}})


def test_an_unconfigured_plugin_has_no_actions() -> None:
    with pytest.raises(ConfigError, match="'on'"):
        load({**CONFIG, "plugins": {}})
    taps_only = {**CONFIG, "plugins": {}, "bindings": CONFIG["bindings"][:1]}
    assert load(taps_only).plugins == {}


def test_rejects_an_empty_action_list() -> None:
    with pytest.raises(ConfigError, match="at least 1"):
        load({**CONFIG, "bindings": [{"key": "KEY_KP1", "actions": []}]})


def test_rejects_two_plugins_with_one_action() -> None:
    plugins = {"lamp": {"room": "a"}, "clash": {"room": "b"}}
    with pytest.raises(ConfigError, match="both define the action 'on'"):
        load({**CONFIG, "plugins": plugins}, {"lamp": Lamp, "clash": Clash})


def test_handlers_map_each_action_to_its_plugin() -> None:
    lamp = Lamp(LampSettings(room="hall"))
    assert handlers({"lamp": lamp}) == {"on": lamp, "dim": lamp}
