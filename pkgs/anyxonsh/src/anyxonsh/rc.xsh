# anyxonsh's bundled run-control file.
#
# Loaded before any user rc (see anyxonsh/__main__.py), so anything set here is
# a default the user's own ~/.config/xonsh/rc.xsh can still override.

# --- History ------------------------------------------------------------
$XONSH_HISTORY_BACKEND = "sqlite"
$XONSH_HISTORY_SIZE = (10000, "commands")
$HISTCONTROL = {"ignoredups", "erasedups"}

# --- Interactive behaviour ----------------------------------------------
$AUTO_CD = True
$AUTO_PUSHD = True
$CASE_SENSITIVE_COMPLETIONS = False
$COMPLETIONS_CONFIRM = True
$UPDATE_OS_ENVIRON = True

# Show the traceback rather than a bare one-line error; this is a shell people
# are meant to hack on.
$XONSH_SHOW_TRACEBACK = True

# --- Prompt -------------------------------------------------------------
# jj, and deliberately not git. This repository is jj-only -- the owner has
# never once wanted a git branch name at a prompt -- so the classic
# {curr_branch} field is gone, and what replaces it talks to jj: the change ID
# of @ and whatever bookmarks point at it, rendered by the `jj_prompt` field
# defined below.
#
# Colour note: every named colour here resolves through the catppuccin-mocha
# map the `catppuccin` xontrib registers below (the sixteen slots of
# Catppuccin's own terminal mapping), so GREEN really is Mocha green and PINK
# really is Mocha pink -- see that module for why the default guess collapses
# half the palette into one grey. Arbitrary palette names ({MAUVE} and
# friends) are not part of that map and render literally; verified headless.
#
# On an SSH session user and host take different colours -- same-colour
# user@host gives no cue about which machine a shell is on, which matters
# precisely when the answer is "not this one". Locally they share green, the
# classic look.
import os as _os
import subprocess as _subprocess

if ${...}.get("SSH_CONNECTION") or ${...}.get("SSH_CLIENT"):
    _userhost = "{BOLD_GREEN}{user}{RESET}{YELLOW}@{hostname}{RESET}"
else:
    _userhost = "{BOLD_GREEN}{user}@{hostname}{RESET}"

$PROMPT = (
    "{env_name}"
    + _userhost
    + ":{BLUE}{cwd}{RESET}{jj_prompt}\n{prompt_end} "
)
$RIGHT_PROMPT = "{last_return_code_if_nonzero:[{BOLD_INTENSE_RED}{}{RESET}] }{short_cwd}"
$TITLE = "{current_job:{} | }{cwd_base} | xonsh"

# The jj prompt fields. One subprocess per *command*, not per keystroke:
# helix sets $UPDATE_PROMPT_ON_KEYPRESS, so a naive field would shell out to
# `jj log` on every keypress. Instead a cached string is re-rendered for free,
# and two events mark it stale -- after each command, and on directory change,
# the two things that can actually alter what jj would report.
_jj_state = {"dirty": True, "render": ""}


def _jj_render():
    """Colour-coded '@change-id bookmarks' for the cwd, or '' outside a repo."""
    d = _os.getcwd()
    while True:
        if _os.path.isdir(_os.path.join(d, ".jj")):
            break
        parent = _os.path.dirname(d)
        if parent == d:
            return ""
        d = parent

    try:
        proc = _subprocess.run(
            ["jj", "log", "-r", "@", "--no-graph",
             "--template", 'change_id.short(8) ++ " " ++ bookmarks.join(" ")'],
            capture_output=True, text=True, timeout=1, cwd=d,
        )
    except (OSError, _subprocess.TimeoutExpired):
        return ""
    words = proc.stdout.split() if proc.returncode == 0 else []

    segment = ""
    if words:
        segment += "{CYAN}@" + words[0] + "{RESET}"
        if len(words) > 1:
            segment += " {PINK}" + " ".join(words[1:]) + "{RESET}"
        segment = " " + segment
    return segment


def _jj_prompt():
    if _jj_state["dirty"]:
        _jj_state["dirty"] = False
        _jj_state["render"] = _jj_render()
    return _jj_state["render"]


$PROMPT_FIELDS["jj_prompt"] = _jj_prompt

from xonsh.events import events as _events


@_events.on_post_command
def _jj_stale_after_command(**_):
    _jj_state["dirty"] = True


@_events.on_chdir
def _jj_stale_after_chdir(**_):
    _jj_state["dirty"] = True

# --- Keyboard protocol --------------------------------------------------
# Ask the terminal once whether it speaks the Kitty keyboard protocol, and if
# so push the disambiguate flag for the life of this shell -- which is what
# turns Shift+Enter into a distinct event the helix bindings can catch as real
# multiline input instead of terminal-dependent escape soup. Probing must
# happen before prompt_toolkit owns stdin (see xontrib_helix.keyboard); it
# no-ops safely without a tty, so no interactivity gate here -- and none of
# the names from later sections either, this file runs top to bottom.
if ${...}.get("ANYXONSH_KEYBOARD", None) is None:
    from xontrib_helix import keyboard as _keyboard

    _keyboard.enable()
    del _keyboard

# --- Line editing -------------------------------------------------------
# `helix` is anyxonsh's default: Helix's selection-then-action model rather
# than Vim's action-then-motion. Shipped as the `helix` xontrib -- see
# src/xontrib/helix.py, src/xontrib_helix/ and the README.
#
# `emacs` is prompt_toolkit's own default and `vi` is xonsh's `$VI_MODE`; both
# leave the Helix code entirely unimported, so choosing them costs nothing.
#
# After the prompt block, because the indicator below prepends to $RIGHT_PROMPT.
$ANYXONSH_EDITING_MODE = ${...}.get("ANYXONSH_EDITING_MODE", "helix")

# Both xontribs below need the prompt_toolkit shell and say so if they do not
# get it -- see `drawn_by_prompt_toolkit` in each package. That is the right
# answer for someone at a readline prompt wondering why their editor is not
# there, and the wrong one for `anyxonsh -c '...'`, which runs this file and
# was never going to draw a prompt at all. So the loads are for interactive
# shells; a non-interactive run is not missing anything it could have used.
_interactive = ${...}.get("XONSH_INTERACTIVE", False)

if $ANYXONSH_EDITING_MODE == "vi":
    $VI_MODE = True
elif $ANYXONSH_EDITING_MODE == "helix" and _interactive:
    xontrib load helix

    # Textual mode indicator on the right side of the prompt, and next to it
    # whatever command is half-typed -- a count, a menu prefix, and the regex
    # while `s` is reading one, which is the one case where not showing it
    # would mean typing blind. Both need $UPDATE_PROMPT_ON_KEYPRESS so they
    # re-render on every keystroke; {helix_pending} brings its own leading
    # space and is empty when there is nothing to say.
    $UPDATE_PROMPT_ON_KEYPRESS = True
    $RIGHT_PROMPT = (
        "{BOLD_INTENSE_YELLOW}{helix_mode}{INTENSE_CYAN}{helix_pending}{RESET} "
        + $RIGHT_PROMPT
    )

# --- The model at the prompt --------------------------------------------
# `: what is this repo about?` asks; `:help` lists the rest. See
# src/xontrib/pai.py, src/xontrib_pai/ and the README.
#
# On by default, at a measured ~50ms of the shell's ~630ms startup. Almost none
# of that is this code -- `xontrib_pai` is three small modules whose stdlib
# imports (typing, pathlib, dataclasses) xonsh has already loaded by then -- it
# is what `xontrib load` itself costs. What is *not* paid here is pydantic-ai,
# about half a second on its own, which nothing imports until a `:` line is
# actually typed.
#
# `$ANYXONSH_AI = False` skips the load entirely for anyone who wants those
# 50ms back.
if ${...}.get("ANYXONSH_AI", True) and _interactive:
    xontrib load pai

    # On by default: commands the overseer considers safe run without asking
    # you first. Set $XONTRIB_PAI_OVERSEER to False to turn it off.
    $XONTRIB_PAI_OVERSEER = ${...}.get("XONTRIB_PAI_OVERSEER", True)

# --- Colour scheme ------------------------------------------------------
# Catppuccin Mocha, shipped as the `catppuccin` xontrib -- see
# src/xontrib/catppuccin.py, src/xontrib_catppuccin/ and the README.
#
# $ANYXONSH_COLOR_STYLE names the style to use, and the xontrib is loaded only
# for its own. Every other value goes straight to $XONSH_COLOR_STYLE, so
# `$ANYXONSH_COLOR_STYLE = "monokai"` -- or any other name `xonfig styles`
# lists -- leaves this code unimported and costs nothing.
#
# The load is for interactive shells, like the two above and for the same
# reason: it is about 60ms of the shell's startup, nearly all of it pygments
# and Catppuccin's palette, and it buys colours that `anyxonsh -c '...'` was
# never going to draw.
$ANYXONSH_COLOR_STYLE = ${...}.get("ANYXONSH_COLOR_STYLE", "catppuccin-mocha")

if _interactive:
    if $ANYXONSH_COLOR_STYLE == "catppuccin-mocha":
        xontrib load catppuccin
    else:
        $XONSH_COLOR_STYLE = $ANYXONSH_COLOR_STYLE

# --- Aliases ------------------------------------------------------------
# Everything here is probed rather than assumed: `mkAnyxonsh`'s `paths` is a
# caller-supplied list, so a downstream flake can build an anyxonsh whose
# closure has neither eza nor an editor. The repo's own defaults ship coreutils
# and eza, but this file must not break when they are absent.
import shutil as _shutil

if _shutil.which("eza"):
    aliases["ll"] = ["eza", "--long", "--git"]
    aliases["la"] = ["eza", "--long", "--all", "--git"]
elif _shutil.which("ls"):
    aliases["ll"] = ["ls", "-lah"]
    aliases["la"] = ["ls", "-A"]

# `nix run` users may land here with no editor configured, and a bare Nix
# closure has no `vi` unless something put one there -- so pick the first that
# actually exists instead of hard-coding a name that may not resolve.
if "EDITOR" not in ${...}:
    for _candidate in ("nvim", "vim", "vi", "nano"):
        if _shutil.which(_candidate):
            $EDITOR = _candidate
            break
    del _candidate

# --- Xontribs -----------------------------------------------------------
# Only load xontribs that are actually present: the Nix side lets callers add or
# drop them (mkAnyxonsh's `xontribs` and `extraPackages`), so a missing one is an
# expected configuration, not an error.
#
# Asking xonsh what it can see, rather than probing with `importlib.find_spec`,
# because a xontrib is not always an importable module path: `fzf-widgets` ships
# as `xontrib/fzf-widgets.xsh` -- a .xsh file whose name isn't even a valid
# Python identifier. `get_xontribs()` keys on the name `xontrib load` expects,
# which is the only name that matters here.
from xonsh.xontribs import get_xontribs as _get_xontribs

_wanted = [
    # Ours: fish's funced/funcsave. Stdlib-only, no external program, so it
    # loads unconditionally -- see src/xontrib_funcs/.
    "funcs",
    # Packaged by nixpkgs
    "vox",
    "jedi",
    "abbrevs",
    "direnv",
    # From nix/extra-packages.nix: PyPI wheels
    "term_integration",
    "cmd_done",
    # From nix/extra-packages.nix: built from source
    "output_search",
    "fzf-widgets",
    "fish_completer",
    "envrc",
]

# `z` -- jump to a directory by frecency. Conditional rather than listed above
# because this one needs a *program*, not just its Python package: it runs
# `zoxide init xonsh` the moment it is imported and does not survive the
# binary's absence -- FileNotFoundError straight through `xontrib load`, taking
# the rest of this file with it. The repo's own `paths` ships `zoxide`, but
# `paths` is a caller-supplied list and a downstream `mkAnyxonsh` can drop it
# while keeping `extraPackages`, so ask rather than assume.
if _shutil.which("zoxide"):
    _wanted.append("zoxide")

_installed = set(_get_xontribs())
for _name in _wanted:
    if _name in _installed:
        xontrib load @(_name)

del _wanted, _installed, _name, _get_xontribs, _shutil, _interactive
# The prompt machinery below is deliberately NOT deleted: xonsh runs this file
# in its own global namespace, so a function defined here resolves `_os`,
# `_jj_state` and friends through that namespace *at call time* -- every
# keystroke re-render of the prompt, long after this file finished. Deleting
# them buys a clean namespace and costs a NameError on the first prompt.
del _events, _userhost
del _jj_stale_after_command, _jj_stale_after_chdir
