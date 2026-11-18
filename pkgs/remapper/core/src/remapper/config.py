"""The configuration file. Each configured plugin adds its settings and actions."""

from __future__ import annotations

import functools
import operator
from dataclasses import dataclass
from typing import TYPE_CHECKING, Annotated, Literal

from evdev import ecodes
from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    JsonValue,
    TypeAdapter,
    ValidationError,
    create_model,
)
from pydantic.alias_generators import to_camel

if TYPE_CHECKING:
    from collections.abc import Mapping

    from .plugin import Plugin


def _keycode(name: str) -> str:
    if name not in ecodes.ecodes or not name.startswith(("KEY_", "BTN_")):
        msg = f"not an evdev key name: {name}"
        raise ValueError(msg)
    return name


def _usb_id(value: str) -> str:
    if len(value) != 4 or any(c not in "0123456789abcdef" for c in value):
        msg = f"not four lowercase hex digits: {value}"
        raise ValueError(msg)
    return value


KeyName = Annotated[str, AfterValidator(_keycode)]
UsbIdPart = Annotated[str, AfterValidator(_usb_id)]


def code(name: str) -> int:
    return ecodes.ecodes[name]


class Model(BaseModel):
    """The base of every settings and action model: frozen, strict, camelCase in JSON."""

    model_config = ConfigDict(
        frozen=True, extra="forbid", alias_generator=to_camel, validate_by_name=True
    )


class UsbDevice(Model):
    vendor: UsbIdPart
    product: UsbIdPart

    @property
    def label(self) -> str:
        return f"{self.vendor}:{self.product}"


class Match(UsbDevice):
    """One event node of a USB device: a receiver exposes several with one name."""

    keys: list[KeyName] = Field(
        default_factory=list, description="Keys the node must report"
    )


class Action(Model):
    """What a binding does. A subclass names itself: `do: Literal["name"] = "name"`."""

    do: str


def action_name(model: type[Action]) -> str:
    return model.model_fields["do"].default


class Tap(Action):
    """A key press and release on the host, from the device "remapper"."""

    do: Literal["tap"] = "tap"
    key: KeyName


class ConfigError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class Binding:
    """`actions` run in order when `key` is released, if `hold` is down then.

    Without `hold`, only when no other key that some binding holds is down.
    """

    key: int
    hold: int | None
    actions: tuple[Action, ...]


@dataclass(frozen=True, slots=True)
class Config:
    numpad: Match
    bindings: tuple[Binding, ...]
    # Validated settings, by plugin name: only the configured plugins.
    plugins: Mapping[str, Model]


class _Head(Model):
    numpad: Match
    # Raw until the plugins are known: each one validates its own settings,
    # and the bindings may use only the actions of configured plugins.
    plugins: dict[str, JsonValue] = Field(default_factory=dict)
    bindings: list[JsonValue]


class _Binding(Model):
    key: KeyName
    hold: KeyName | None = None


def actions_of(plugins: Mapping[str, type[Plugin]]) -> list[type[Action]]:
    """Tap and every action of `plugins`. Two plugins may not share a name."""
    owner = {action_name(Tap): "remapper"}
    models: list[type[Action]] = [Tap]
    for name, plugin in plugins.items():
        for model in plugin.actions:
            do = action_name(model)
            if do in owner:
                msg = f"plugins {owner[do]} and {name} both define the action {do!r}"
                raise ConfigError(msg)
            owner[do] = name
            models.append(model)
    return models


def parse(data: bytes | str, installed: Mapping[str, type[Plugin]]) -> Config:
    """The configuration in `data`, for the plugins in `installed`."""
    try:
        head = _Head.model_validate_json(data)
    except ValidationError as e:
        raise ConfigError(str(e)) from e
    unknown = sorted(set(head.plugins) - set(installed))
    if unknown:
        msg = (
            f"no plugin named {', '.join(unknown)}; "
            f"installed: {', '.join(sorted(installed)) or 'none'}"
        )
        raise ConfigError(msg)
    enabled = {name: installed[name] for name in head.plugins}
    settings: dict[str, Model] = {}
    for name, plugin in enabled.items():
        try:
            settings[name] = plugin.Settings.model_validate(head.plugins[name])
        except ValidationError as e:
            msg = f"plugins.{name}: {e}"
            raise ConfigError(msg) from e

    models = actions_of(enabled)
    # A one-member union is the member itself, and a discriminator needs a union.
    # The union exists only at runtime, so the type checker cannot follow it.
    action = (
        Annotated[functools.reduce(operator.or_, models), Field(discriminator="do")]  # pyrefly: ignore[invalid-annotation]
        if len(models) > 1
        else Tap
    )
    binding = create_model(
        "Binding",
        __base__=_Binding,
        actions=(list[action], Field(min_length=1)),
    )
    try:
        raw = TypeAdapter(list[binding]).validate_python(head.bindings)
    except ValidationError as e:
        msg = f"bindings: {e}"
        raise ConfigError(msg) from e
    bindings = tuple(
        Binding(
            code(b.key),
            code(b.hold) if b.hold is not None else None,
            tuple(b.actions),  # pyrefly: ignore[missing-attribute] -- from create_model
        )
        for b in raw
    )
    return Config(head.numpad, bindings, settings)
