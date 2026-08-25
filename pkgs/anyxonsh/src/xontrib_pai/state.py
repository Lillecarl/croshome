"""Reading and writing the session's own state, without asking.

`run_xonsh` can already do all of this -- `$EDITOR`, `${...}.get('X')`, `x = 1`
-- so this module is not about capability. It is about cost. Answering "what is
`$XONSH_HISTORY_BACKEND` set to" through `run_xonsh` costs an approval prompt, a
terminal handover, and a human deciding whether `print($X)` is safe; it is the
same interruption as `rm -rf` for a question with no consequences. Tools that
need permission get used sparingly, which in practice means the model guesses
about the environment instead of looking.

So these two are quiet, like the file tools: they run on the worker thread, they
never touch the terminal, and no overseer sees them. What justifies that is a
much narrower reach than an execer -- names in `XSH.env` and `XSH.ctx`, values
that arrive as data rather than as source. There is no expression to evaluate
here, so there is nothing to evaluate an expression *into*.

Two things are not quiet, and deliberately:

* **A write is shown.** It changed something of the user's session, so the
  before and after go on the terminal the way an edited file's diff does.
* **Values that look like secrets are not returned.** Everything else here is
  the user asking for their own state back; an API key read without anyone
  seeing it is the model being handed a credential, which is the one thing in
  reach that leaves the machine. The name and type still come back, and
  `run_xonsh` will print the value once someone approves it.

Xonsh's own vocabulary is the interface: `$NAME` is an environment variable and
a bare `name` is a Python name in the session, exactly as at the prompt. The
model is already told that syntax in its instructions, so there is nothing new
to learn and no `scope=` argument to get wrong.
"""

from __future__ import annotations

import fnmatch
import json
import re

from .files import _fail

#: How much of one value to show. Generous for a single lookup -- `$PATH` and
#: `$PROMPT` are both long and both worth seeing whole -- and tight in a listing,
#: where the question is which names exist rather than what each one holds.
MAX_VALUE = 800
MAX_ROW = 100
MAX_ROWS = 120

#: How much of an environment variable's documentation to pass on. Xonsh's docs
#: are a paragraph or two; the first part says what it does and the rest is
#: usually about how it is rendered.
MAX_DOC = 700

#: Name parts that mean "this value is a credential". Matched against the
#: `_`-separated parts of a name, so `DEEPSEEK_API_KEY` is hidden and
#: `LESSKEYIN_SYSTEM` is not.
#:
#: It over-matches -- `$PROMPT_TOKENS_FORMATTER` is not a secret -- and that is
#: the direction to be wrong in. A false positive costs one approved command; a
#: false negative hands a key to a model unprompted and unseen.
SECRET_PARTS = frozenset(
    {
        "KEY",
        "KEYS",
        "TOKEN",
        "TOKENS",
        "SECRET",
        "SECRETS",
        "PASSWORD",
        "PASSWD",
        "PASS",
        "CREDENTIAL",
        "CREDENTIALS",
    }
)

HIDDEN = "[hidden: looks like a credential; run_xonsh can print it if you ask]"

#: Names in the session namespace that are never worth listing: Python's own
#: furniture, and the handle this xontrib keeps on itself.
_UNINTERESTING = re.compile(r"^(__.*__|_+\d*|__pai__)$")


def secret(name: str) -> bool:
    """Would returning this value be handing over a credential?"""
    return bool(SECRET_PARTS & set(name.upper().split("_")))


def _shell():
    """The loaded xonsh session, or `None` outside one."""
    try:
        from xonsh.built_ins import XSH
    except ImportError:
        return None
    return XSH if getattr(XSH, "env", None) is not None else None


def _value(name: str, value, limit: int) -> str:
    """One value, as the model may see it."""
    if secret(name):
        return HIDDEN
    shown = repr(value)
    if len(shown) > limit:
        return f"{shown[:limit]}... [{len(shown) - limit} more characters]"
    return shown


def _glob(pattern: str) -> bool:
    return any(character in pattern for character in "*?[")


def _matching(names, pattern: str) -> list[str]:
    return sorted(n for n in names if fnmatch.fnmatchcase(n, pattern))


def _env_detail(env, name: str) -> str:
    """One environment variable, with what xonsh knows about it."""
    lines = [f"${name} = {_value(name, env[name], MAX_VALUE)}"]
    lines.append(f"  type: {type(env[name]).__name__}")

    docs = env.get_docs(name)
    default = getattr(docs, "doc_default", "") or ""
    if not default:
        raw = getattr(docs, "default", "")
        default = repr(raw) if raw != "" else ""
    if default:
        lines.append(f"  default: {default}")
    try:
        if env.is_manually_set(name):
            lines.append("  set in this session or inherited, not the xonsh default")
    except Exception:  # noqa: BLE001 - xonsh does not promise this for every name
        pass

    doc = " ".join((getattr(docs, "doc", "") or "").split())
    if doc:
        if len(doc) > MAX_DOC:
            doc = doc[:MAX_DOC] + "..."
        lines.append(f"  doc: {doc}")
    return "\n".join(lines)


def _name_detail(ctx, name: str) -> str:
    """One Python name from the session namespace."""
    value = ctx[name]
    return f"{name} = {_value(name, value, MAX_VALUE)}\n  type: {type(value).__name__}"


def _rows(items, prefix: str) -> list[str]:
    rows = []
    for name, value in items:
        rows.append(f"{prefix}{name} = {_value(name, value, MAX_ROW)}")
        if len(rows) >= MAX_ROWS:
            rows.append(f"[stopped at {MAX_ROWS} names; narrow the pattern]")
            break
    return rows


def _overview(shell) -> str:
    """What is worth saying when asked for everything.

    Dumping 289 environment variables would answer a question nobody asked and
    cost more context than the conversation it is part of. The variables the
    user has actually set are the interesting ones -- their configuration, as
    opposed to xonsh's defaults -- so that is what an empty pattern means.
    """
    env = shell.env
    names = []
    for name in sorted(env.keys()):
        try:
            if env.is_manually_set(name):
                names.append(name)
        except Exception:  # noqa: BLE001 - not promised for unregistered names
            continue
    rows = _rows(((n, env[n]) for n in names), "$")
    total = len(list(env.keys()))
    header = (
        f"{total} environment variables in this session; "
        f"{len(names)} of them set rather than left at the xonsh default:"
    )
    tail = (
        "\nAsk for one by name (`$XONSH_HISTORY_BACKEND`) for its type, default "
        "and documentation, or use a pattern (`$XONSH_*`, `$*PROXY*`)."
    )
    return "\n".join([header, *rows]) + tail


def show_state(name: str = "") -> str:
    """Read environment variables and Python names from the user's session.

    Quiet and immediate -- no permission needed, so prefer it to running
    `print($X)` through `run_xonsh` whenever you want to know how the shell is
    configured. Values that look like credentials come back hidden.

    Args:
        name: `$NAME` for an environment variable, a bare `name` for a Python
            name in the session. Globs work on either side (`$XONSH_*`,
            `$*PROXY*`). Leave it empty for the variables the user has actually
            set, which is the useful summary of a shell.
    """
    shell = _shell()
    if shell is None:
        return _fail("There is no xonsh session to read.")
    env, ctx = shell.env, shell.ctx

    name = name.strip()
    if not name:
        return _overview(shell)

    if name.startswith("$"):
        bare = name[1:]
        if not bare:
            return _fail("Nothing after the `$`. Try `$PATH` or `$XONSH_*`.")
        if _glob(bare):
            found = _matching(env.keys(), bare)
            if not found:
                return f"No environment variable matches {name}."
            return "\n".join(_rows(((n, env[n]) for n in found), "$"))
        if bare not in env:
            docs = env.get_docs(bare)
            known = getattr(docs, "doc", "")
            if known:
                return (
                    f"{name} is not set. It is a xonsh variable, currently at its "
                    f"default {getattr(docs, 'doc_default', '') or getattr(docs, 'default', '')!r}."
                )
            return f"{name} is not set, and xonsh does not know that name."
        return _env_detail(env, bare)

    if _glob(name):
        found = [n for n in _matching(ctx.keys(), name) if not _UNINTERESTING.match(n)]
        if not found:
            return f"No name in the session matches {name!r}."
        return "\n".join(_rows(((n, ctx[n]) for n in found), ""))
    if name not in ctx:
        return (
            f"{name!r} is not defined in the session. "
            f"Environment variables need the `$`: `${name}`."
        )
    return _name_detail(ctx, name)


def _parse(value: str):
    """The text the model sent, as a Python value.

    JSON first, so a list stays a list and `true` stays a boolean -- `$PATH` is
    a list of strings and `$XONSH_SHOW_TRACEBACK` is a bool, and getting a
    string into either of those places is how a shell breaks quietly. Anything
    JSON refuses is taken as the string it looks like, because the common case
    is `$EDITOR` being set to `nvim` and demanding `"nvim"` there would be a
    trap rather than a feature.
    """
    try:
        return json.loads(value)
    except (ValueError, TypeError):
        return value


def _acceptable(env, name: str, value):
    """`(value, None)` if xonsh will take this, `(None, why)` if it will not.

    Worth doing here because `XSH.env['X'] = y` does not: assignment stores
    whatever it is given, so `$XONSH_SHOW_TRACEBACK = 'maybe'` succeeds and then
    misbehaves somewhere else entirely, at a moment with nothing to connect it
    back to this. A tool that changes a live shell without a human looking at
    each call should not be the thing that leaves it in that state.

    Xonsh's converters do the rest of the work, because several variables hold
    types JSON cannot express: `$PATH` wants an `EnvPath` and rejects the plain
    list that would be the obvious way to write one, and `$XONSH_HISTORY_SIZE`
    wants `(100, 'commands')`. Converting a list into those is the whole reason
    the converters exist.

    They are applied to structure only, never to a string. Not a detail: xonsh's
    `to_bool` is total, and reads every string it does not recognise as `True`,
    so a string route would turn `$XONSH_SHOW_TRACEBACK = 'maybe-later'` into a
    quiet yes. A boolean is `true` in JSON and there is nothing to be forgiving
    about; a string stays the string it was.
    """
    validate = env.get_validator(name)
    if validate is None or validate(value):
        return value, None

    convert = env.get_converter(name)
    if convert is not None and not isinstance(value, str):
        try:
            converted = convert(value)
        except Exception:  # noqa: BLE001 - a refusal, reported below
            converted = None
        if converted is not None and validate(converted):
            return converted, None

    docs = env.get_docs(name)
    raw = getattr(docs, "default", "")
    default = getattr(docs, "doc_default", "") or repr(raw)
    doc = " ".join((getattr(docs, "doc", "") or "").split())
    why = (
        f"${name} does not accept {value!r}. It holds a "
        f"{type(env[name]).__name__ if name in env else type(raw).__name__}; "
        f"its default is {default}."
    )
    return None, f"{why} {doc[:200]}" if doc else why


def set_state(name: str, value: str) -> str:
    """Set an environment variable or a Python name in the user's session.

    This changes the live shell and the change is still there at their next
    prompt, so it is shown to them as it happens. It needs no permission, but it
    is still their session: change what was asked for and say that you did.

    Args:
        name: `$NAME` for an environment variable, a bare `name` for a Python
            name.
        value: JSON, so that types survive -- `["/a","/b"]` for `$PATH`, `true`
            for a boolean, `3` for a number. Anything that is not JSON is taken
            as the string it looks like, so `nvim` works for `$EDITOR`.
    """
    from .progress import note

    shell = _shell()
    if shell is None:
        return _fail("There is no xonsh session to change.")
    env, ctx = shell.env, shell.ctx

    name = name.strip()
    if not name:
        return _fail("No name given.")
    if _glob(name):
        return _fail("One name at a time; patterns are for reading.")

    wanted = _parse(value)

    if name.startswith("$"):
        bare = name[1:]
        if not bare:
            return _fail("Nothing after the `$`. Try `$EDITOR`.")
        accepted, why = _acceptable(env, bare, wanted)
        if why is not None:
            return _fail(why)
        had = bare in env
        before = _value(bare, env[bare], MAX_ROW) if had else "(unset)"
        env[bare] = accepted
        after = _value(bare, env[bare], MAX_ROW)
        note(f"  ${bare}: {before} -> {after}")
        return f"${bare} = {after} (type {type(env[bare]).__name__})"

    if not name.isidentifier():
        return _fail(
            f"{name!r} is not a Python name. Environment variables need a `$`."
        )
    before = _value(name, ctx[name], MAX_ROW) if name in ctx else "(unset)"
    ctx[name] = wanted
    after = _value(name, ctx[name], MAX_ROW)
    note(f"  {name}: {before} -> {after}")
    return f"{name} = {after} (type {type(wanted).__name__})"


#: What the agent registers, in a fixed order. Tool order is part of the request
#: prefix, so this is a written-out list rather than whatever iteration produces
#: -- see the note in `agent.py` about what reordering costs.
TOOLS = [show_state, set_state]
