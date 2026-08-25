"""Catppuccin Mocha, wired into both halves of xonsh's colour machinery.

Catppuccin already ships a Python package, and it is the source of every colour
here: `catppuccin.PALETTE` for the values and a `pygments.styles` entry point
per flavour for the syntax highlighting. Nothing in this module is a copy of
those, because a copy is a thing that drifts.

What the package alone does not give you is a *shell*. xonsh colours two
different things through two different maps:

* **Syntax highlighting** -- the command line as you type it, tracebacks, `cat`
  through pygments. This is an ordinary pygments style, and
  `catppuccin[pygments]` is exactly that. `$XONSH_COLOR_STYLE =
  "catppuccin-mocha"` gets it with no xontrib at all.
* **Everything named** -- `$PROMPT`'s `{BOLD_GREEN}`, `$RIGHT_PROMPT`'s
  `{BOLD_INTENSE_RED}`, `printx` colour format strings, `$LS_COLORS`. These go
  through `Token.Color.*`, sixteen named slots that are not pygments tokens and
  that no pygments style declares.

For the second map xonsh guesses. `pygments_style_by_name` collects the
distinct colours a style mentions and runs `find_closest_color` for each of the
sixteen names, and on Catppuccin that guess collapses: `BLACK`, `RED`, `GREEN`,
`YELLOW`, `BLUE`, `PURPLE`, `CYAN` and `INTENSE_BLACK` -- eight of the sixteen
-- all come back as `#6c7086`, one grey. anyxonsh's own prompt is
`{BOLD_GREEN}{user}@{hostname}` then `{BOLD_BLUE}{cwd}`, which is that grey
twice. The ANSI map (`ansi_style_by_name`, used by the readline shell) is
derived the same way and lands in the same place, and drops the `BACKGROUND_*`
names entirely while it is there.

So this module supplies that map by hand, from Catppuccin's own terminal
mapping -- the sixteen slots every Catppuccin terminal port ships -- and
registers it under the same name the pygments entry point uses. `xontrib load
catppuccin` therefore does not replace `$XONSH_COLOR_STYLE =
"catppuccin-mocha"`; it makes it correct.
"""

from __future__ import annotations

from dataclasses import dataclass

#: The flavour this xontrib themes the shell with, and the name both maps are
#: registered under -- deliberately the same string Catppuccin's own pygments
#: entry point uses, so there is one spelling of "Catppuccin Mocha" and loading
#: the xontrib upgrades it rather than introducing a second one.
FLAVOUR = "mocha"
STYLE_NAME = f"catppuccin-{FLAVOUR}"

#: Catppuccin's terminal ANSI mapping, as palette colour names, against the
#: sixteen slots xonsh calls `Token.Color.*`. Copied from the terminal ports
#: (alacritty, kitty, foot, wezterm -- they all agree), not invented here.
#:
#: Two things about it surprise people, and both are upstream's intent:
#:
#: * Slots 9-14 -- the bright half of red through cyan -- are the same colours
#:   as 1-6. Catppuccin has one red, and a "bright red" that is a different red
#:   is not it. Only black and white have distinct bright variants.
#: * Bright white (`subtext0`) is *dimmer* than normal white (`subtext1`), and
#:   normal black (`surface1`) is lighter than a terminal's usual black. The
#:   sixteen slots are laid out across the middle of the palette on purpose:
#:   there is no pure black or pure white in Catppuccin to put at the ends.
#:
#: Mocha only, and not by accident. Frappé and Macchiato use these same names,
#: but Latte is the light flavour and swaps its ends -- black is `subtext1`,
#: white is `surface2` -- so this table is not the flavour-agnostic thing it
#: looks like, and a loop over `PALETTE` would quietly get Latte wrong.
ANSI_SLOTS = {
    "BLACK": "surface1",
    "RED": "red",
    "GREEN": "green",
    "YELLOW": "yellow",
    # Slot 5 is magenta everywhere else; xonsh is the one that calls it PURPLE.
    "PURPLE": "pink",
    "BLUE": "blue",
    "CYAN": "teal",
    "WHITE": "subtext1",
    "INTENSE_BLACK": "surface2",
    "INTENSE_RED": "red",
    "INTENSE_GREEN": "green",
    "INTENSE_YELLOW": "yellow",
    "INTENSE_PURPLE": "pink",
    "INTENSE_BLUE": "blue",
    "INTENSE_CYAN": "teal",
    "INTENSE_WHITE": "subtext0",
}


def color_tokens() -> dict[str, str]:
    """The sixteen named slots, plus their backgrounds, as a xonsh style dict.

    One dict for both registrations, which works because the two functions
    parse their keys the same way: `Color.RED` is `Token.Color.RED` to
    `register_custom_pygments_style` and the bare name `RED` to
    `register_custom_ansi_style`.

    The `BACKGROUND_*` half is only read by the ANSI side -- the pygments path
    synthesises a background from the foreground in `code_by_name`. It is here
    anyway because leaving it out is how the derived style ends up with no
    `BACKGROUND_RED` at all, and a `$PROMPT` that asks for one gets nothing.
    """
    from catppuccin import PALETTE

    colors = getattr(PALETTE, FLAVOUR).colors
    tokens = {}
    for slot, color in ANSI_SLOTS.items():
        value = getattr(colors, color).hex
        tokens[f"Color.{slot}"] = value
        tokens[f"Color.BACKGROUND_{slot}"] = f"bg:{value}"
    return tokens


def register() -> str:
    """Register both maps under `STYLE_NAME`, and return that name.

    Idempotent: registering twice writes the same two entries again. Both
    registrations take Catppuccin's pygments style as their base, so every
    token this does not name -- the whole syntax half -- stays exactly what
    upstream declared, including the `mantle` background and `surface0`
    highlight the style carries.
    """
    from xonsh.ansi_colors import register_custom_ansi_style
    from xonsh.pyghooks import register_custom_pygments_style

    tokens = color_tokens()
    register_custom_pygments_style(STYLE_NAME, tokens, base=STYLE_NAME)
    register_custom_ansi_style(STYLE_NAME, tokens, base=STYLE_NAME)
    return STYLE_NAME


@dataclass
class Installation:
    """What `xontrib load catppuccin` did, and how to put it back."""

    #: The style now in `$XONSH_COLOR_STYLE`.
    style_name: str
    #: What was there before, or None if the variable was unset.
    previous: str | None

    def uninstall(self) -> None:
        """Restore `$XONSH_COLOR_STYLE`.

        Only if it still says what this installation put there: a user who ran
        `$XONSH_COLOR_STYLE = "monokai"` after loading has already chosen, and
        unloading the xontrib should not overrule them.
        """
        from xonsh.built_ins import XSH

        env = XSH.env
        if env is None or env.get("XONSH_COLOR_STYLE") != self.style_name:
            return
        if self.previous is None:
            env.pop("XONSH_COLOR_STYLE", None)
        else:
            env["XONSH_COLOR_STYLE"] = self.previous


def setup() -> Installation:
    """Register the style and make it the current one."""
    from xonsh.built_ins import XSH

    style_name = register()

    env = XSH.env
    previous = None if env is None else env.get("XONSH_COLOR_STYLE")
    if env is not None:
        # The prompt_toolkit shell re-reads this on every prompt, so a live
        # session repaints on the next keystroke -- no restart needed.
        env["XONSH_COLOR_STYLE"] = style_name

    return Installation(style_name=style_name, previous=previous)
