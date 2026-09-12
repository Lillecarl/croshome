"""Extract pymux's commands.py into one module per command.

Run from a pymux checkout:  pyedit -s examples/pyedit/extract-commands.py [--apply]
"""
import ast
import re

ROOT = "pymux/commands"
SRC = ROOT + "/commands.py"
text = pyedit.read(SRC)
lines = text.splitlines(keepends=True)
mod = ast.parse(text)

errors = []

def seg(node):
    "Exact text of a node, decorators dropped."
    if node.decorator_list:
        start = max(d.end_lineno for d in node.decorator_list)
    else:
        start = node.lineno - 1
    return "".join(lines[start:node.end_lineno])

funcs = {n.name: n for n in mod.body if isinstance(n, ast.FunctionDef)}

CORE_FUNCS = {
    "has_command_handler", "get_documentation_for_command", "get_option_flags_for_command",
    "handle_command", "call_command_handler", "declarer", "_command", "add_commands_to",
    "_variables_of", "_shlex_that_keeps_a_hash", "_build_the_tree", "_options", "_wrapper",
}

declarers = {
    n.name: n for n in mod.body
    if isinstance(n, ast.FunctionDef)
    and any(getattr(d, "id", None) == "declarer" for d in n.decorator_list)
}

class Cmd:
    def __init__(self, decl):
        self.decl = decl
        self.handler = None
        self.name = None
        self.aliases = ()
        self.dest = {}

cmds = []
for dname in sorted(declarers, key=lambda n: declarers[n].lineno):
    d = declarers[dname]
    c = Cmd(d)
    for node in ast.walk(d):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "_command":
            c.handler = node.args[1].id
            for kw in node.keywords:
                if kw.arg == "name":
                    c.name = kw.value.value
                elif kw.arg == "aliases":
                    c.aliases = tuple(e.value for e in kw.value.elts)
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "add_argument":
            opts, positional = [], None
            for a in node.args:
                if isinstance(a, ast.Constant) and isinstance(a.value, str):
                    if a.value.startswith("-"):
                        opts.append(a.value)
                    else:
                        positional = a.value
            kw = {k.arg: k.value for k in node.keywords if isinstance(k.value, ast.Constant)}
            if positional is not None:
                dest = positional
                if "metavar" in kw:
                    c.dest["<%s>" % kw["metavar"].value.strip("<>")] = dest
            else:
                if "dest" in kw:
                    dest = kw["dest"].value
                elif "metavar" in kw:
                    dest = kw["metavar"].value.strip("<>").replace("-", "_")
                else:
                    dest = max(opts, key=len).lstrip("-").replace("-", "_")
                for o in opts:
                    c.dest[o] = dest
                if "metavar" in kw:
                    c.dest["<%s>" % kw["metavar"].value.strip("<>")] = dest
            c.dest[positional] = dest
    if c.handler is None:
        errors.append("declarer %s: no _command call found" % dname)
        continue
    cmds.append(c)

handler_of = {c.handler: c for c in cmds}
handlers = set(handler_of)
helpers = [n for n in funcs if n not in handlers and n not in CORE_FUNCS and n not in declarers]

helper_users = {h: set() for h in helpers}
for c in cmds:
    seen = {n.id for n in ast.walk(c.decl) if isinstance(n, ast.Name)}
    seen |= {n.id for n in ast.walk(funcs[c.handler]) if isinstance(n, ast.Name)}
    for h in helpers:
        if h in seen:
            helper_users[h].add(c.handler)

common_helpers = {h for h, users in helper_users.items() if len(users) >= 2}
changed = True
while changed:
    changed = False
    for h in helpers:
        if h in common_helpers:
            continue
        deps = {n.id for n in ast.walk(funcs[h]) if isinstance(n, ast.Name)} & set(helpers)
        if any(d in common_helpers for d in deps if d != h):
            common_helpers.add(h)
            changed = True
            continue
        # a helper a common helper uses is common too
        if any(
            h in {n.id for n in ast.walk(funcs[g]) if isinstance(n, ast.Name)}
            for g in common_helpers if g != h
        ):
            common_helpers.add(h)
            changed = True

WHITELIST = {
    "Woke": ("pymux.enums", ["Woke"]),
    "WindowSize": ("pymux.enums", ["WindowSize"]),
    "LayoutTypes": ("pymux.arrangement", ["LayoutTypes"]),
    "format_pymux_string": ("pymux.format", ["format_pymux_string"]),
    "ALL_OPTIONS": ("pymux.options", ["ALL_OPTIONS"]),
    "ALL_WINDOW_OPTIONS": ("pymux.options", ["ALL_WINDOW_OPTIONS"]),
    "SetOptionError": ("pymux.options", ["SetOptionError"]),
    "InMemoryHistory": ("prompt_toolkit.history", ["InMemoryHistory"]),
    "get_app": ("prompt_toolkit.application.current", ["get_app"]),
    "ClipboardData": ("prompt_toolkit.clipboard", ["ClipboardData"]),
    "Size": ("prompt_toolkit.data_structures", ["Size"]),
    "Document": ("prompt_toolkit.document", ["Document"]),
    "InputMode": ("prompt_toolkit.key_binding.vi_state", ["InputMode"]),
    "introspect": ("pymux.introspect", None),
    "wrap_argument": ("pymux.commands.utils", ["wrap_argument"]),
    "KeyCompleter": ("pymux.key_spelling", ["KeyCompleter"]),
    "event_however_it_is_written": ("pymux.key_spelling", ["event_however_it_is_written"]),
    "why_a_pane_cannot_read": ("pymux.key_spelling", ["why_a_pane_cannot_read"]),
    "Unhearable": ("pyte.keys", ["Unhearable"]),
    "focus_down": ("pymux.layout", ["focus_down"]),
    "focus_left": ("pymux.layout", ["focus_left"]),
    "focus_right": ("pymux.layout", ["focus_right"]),
    "focus_up": ("pymux.layout", ["focus_up"]),
    "change_pane_size": ("pymux.layout", ["change_pane_size"]),
    "logger": ("pymux.log", ["logger"]),
    "add_command": ("pymux.commands", ["add_command"]),
    "CommandException": ("pymux.commands", ["CommandException"]),
    "handle_command": ("pymux.commands", ["handle_command"]),
    "ALIASES": ("pymux.commands.aliases", ["ALIASES"]),
    "add_commands_to": ("pymux.commands", ["add_commands_to"]),
    "argcomplete": ("argcomplete", None),
}
for h in helpers:
    WHITELIST[h.lstrip("_")] = ("pymux.commands.common", [h.lstrip("_")])
for hname in handlers:
    WHITELIST[hname] = ("pymux.commands." + hname, [hname])

STDLIB = {"argparse", "os", "shlex", "inspect", "sys", "re"}
import builtins
BUILTIN = set(dir(builtins)) | {
    "pymux", "args", "self",
}

def rewrite_variables(node, dest_map, label):
    "variables[...] / variables.get(...) / bare variables -> args.attr; signature spelled for argparse."
    body = seg(node)
    blines = body.splitlines(keepends=True)
    bmod = ast.parse(body)
    edits = {}

    def add(lineno, col, end, rep):
        edits.setdefault((lineno, col), (end, rep))

    for n in ast.walk(bmod):
        if isinstance(n, ast.Subscript) and isinstance(n.value, ast.Name) and n.value.id == "variables":
            key = n.slice.value if isinstance(n.slice, ast.Constant) else None
            if key is None or key not in dest_map:
                errors.append("%s:%d: non-constant variables key -- hand-fix" % (label, n.lineno))
                continue
            add(n.lineno, n.col_offset, n.end_col_offset, "args." + dest_map[key])
        elif isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "get" \
                and isinstance(n.func.value, ast.Name) and n.func.value.id == "variables" and n.args:
            key = n.args[0].value if isinstance(n.args[0], ast.Constant) else None
            if key is None or key not in dest_map:
                errors.append("%s:%d: unknown variables.get key %r" % (label, n.lineno, key))
                continue
            add(n.lineno, n.col_offset, n.end_col_offset, "args." + dest_map[key])
        elif isinstance(n, ast.Name) and n.id == "variables" and isinstance(n.ctx, ast.Load):
            add(n.lineno, n.col_offset, n.end_col_offset, "args")
        elif isinstance(n, (ast.Assign, ast.AugAssign)) and (
            any(isinstance(t, ast.Name) and t.id == "variables" for t in getattr(n, "targets", []))
            or (isinstance(getattr(n, "target", None), ast.Name) and n.target.id == "variables")
        ):
            errors.append("%s:%d: assigns to variables -- hand-fix" % (label, n.lineno))
    for (lineno, col), (end, rep) in sorted(edits.items(), reverse=True):
        ls = blines[lineno - 1]
        blines[lineno - 1] = ls[:col] + rep + ls[end:]
    new = "".join(blines)
    new = new.replace('pymux: "Pymux", variables: _VariablesDict', 'pymux: "Pymux", args: argparse.Namespace')
    new = new.replace("variables: _VariablesDict", "args: argparse.Namespace")
    return new

def free_names(module_text):
    tree = ast.parse(module_text)
    names, bound = set(), set()

    def visit(n):
        if isinstance(n, ast.Name):
            (bound if isinstance(n.ctx, (ast.Store, ast.Del)) else names).add(n.id)
        elif isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name):
            names.add(n.value.id)
        elif isinstance(n, (ast.arg,)):
            bound.add(n.arg)
        elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            bound.add(n.name)
        elif isinstance(n, ast.ExceptHandler) and n.name:
            bound.add(n.name)
        for child in ast.iter_child_nodes(n):
            visit(child)

    visit(tree)
    return names - bound

def annotation_names(tree):
    "The class names quoted in annotations, which are not Name nodes."
    found = set()
    for n in ast.walk(tree):
        for ann in (getattr(n, "annotation", None), getattr(n, "returns", None)):
            if ann is None:
                continue
            for a in ast.walk(ann):
                if isinstance(a, ast.Constant) and a.value in ("Pymux", "Window", "Pane"):
                    found.add(a.value)
    return found

def import_block(module_text, defined, label=""):
    tree = ast.parse(module_text)
    names = free_names(module_text) | annotation_names(tree)
    std, third, first, typing = set(), set(), set(), set()
    for name in sorted(names):
        if name in defined or name in BUILTIN or re.match(r"^\w+$", name) is None:
            continue
        if name in ("List", "Optional", "Any", "Dict", "Callable", "Union", "TYPE_CHECKING"):
            typing.add(name)
        elif name in STDLIB:
            std.add(name)
        elif name in WHITELIST:
            m, items = WHITELIST[name]
            if items is None:
                (third if m == "argcomplete" else first).add("import %s" % m)
            else:
                (first if m.startswith(("pymux", "pyte")) else third).add(
                    "from %s import %s" % (m, ", ".join(items)))
        elif name in ("Pymux", "Window", "Pane"):
            typing.add(name)
        else:
            errors.append("%s: unmapped name %r" % (label, name))
    out = []
    if std:
        out.extend("import %s\n" % s for s in sorted(std))
    if typing - {"TYPE_CHECKING", "Pymux", "Window", "Pane"}:
        out.append(
            "from typing import %s\n" % ", ".join(sorted(typing - {"TYPE_CHECKING", "Pymux", "Window", "Pane"}))
        )
    if "TYPE_CHECKING" in typing or (typing & {"Pymux", "Window", "Pane"}):
        out.append("from typing import TYPE_CHECKING\n\nif TYPE_CHECKING:\n")
        for t in sorted(typing & {"Pymux", "Window", "Pane"}):
            out.append(
                "    from %s import %s\n" % ("pymux.main" if t == "Pymux" else "pymux.arrangement", t)
            )
        out.append("\n")
    if third or first:
        out.append("\n")
        for line in sorted(third | first):
            out.append(line + "\n")
    out.append("\n\n")
    return "".join(out)

emitted = {}
for c in cmds:
    hname = c.handler
    hnode = funcs[hname]
    func_name = c.name.replace("-", "_") if hname == "_" else hname
    htext = rewrite_variables(hnode, c.dest, hname)
    if hname == "_":
        htext = re.sub(r"\b_\(", func_name + "(", htext)

    dtext = seg(c.decl)
    dlines = dtext.splitlines(keepends=True)
    dlines[0] = "def register(subparsers):\n"
    dtext = "".join(dlines)
    dtext = re.sub(r"\b_command\(", "add_command(", dtext)
    if hname == "_":
        dtext = re.sub(r"add_command\(subparsers, _\)", "add_command(subparsers, %s)" % func_name, dtext)
    dm = ast.parse(dtext)
    inj = []
    for node in ast.walk(dm):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "add_argument" and node.args:
            first = node.args[0]
            if isinstance(first, ast.Constant) and first.value.startswith("-") \
                    and not any(k.arg == "dest" for k in node.keywords):
                kw = {k.arg: k.value for k in node.keywords if isinstance(k.value, ast.Constant)}
                dest = kw["metavar"].value.strip("<>").replace("-", "_") if "metavar" in kw \
                    else first.value.lstrip("-").replace("-", "_")
                inj.append((first.end_lineno, first.end_col_offset, ', dest="%s"' % dest))
    dl = dtext.splitlines(keepends=True)
    for lineno, col, rep in sorted(inj, reverse=True):
        ls = dl[lineno - 1]
        dl[lineno - 1] = ls[:col] + rep + ls[col:]
    dtext = "".join(dl)

    body = htext.rstrip() + "\n\n\n" + dtext.rstrip() + "\n"
    defined = {func_name, "register"}
    # single-use helpers join the module that uses them
    for h in sorted(set(helpers) - common_helpers):
        if helper_users[h] == {hname}:
            helper_text = rewrite_variables(funcs[h], c.dest, h).rstrip()
            body = helper_text + "\n\n\n" + body
            defined.add(h.lstrip("_"))
    for h in sorted(set(helpers) - common_helpers):
        if helper_users[h] == {hname}:
            body = re.sub(r"\b%s\b" % re.escape(h), h.lstrip("_"), body)
            defined.add(h.lstrip("_"))
    body = re.sub(r"\b%s\b" % "_", "_", body) if False else body
    # rename every referenced helper to its stripped name
    for h in sorted(helpers):
        if h.startswith("_"):
            body = re.sub(r"\b%s\b" % re.escape(h), h.lstrip("_"), body)

    imports = import_block(body, defined)
    module_text = imports + body
    ast.parse(module_text)
    emitted[c.name.replace("-", "_") if c.name else func_name] = module_text

common_parts = []
for h in sorted(common_helpers, key=lambda n: funcs[n].lineno):
    t = rewrite_variables(funcs[h], {"-g": "g"}, h)
    common_parts.append(re.sub(r"\b%s\b" % re.escape(h), h.lstrip("_"), t).rstrip() + "\n")
common_text = "\n\n".join(common_parts)
for h in sorted(helpers):
    if h.startswith("_"):
        common_text = re.sub(r"\b%s\b" % re.escape(h), h.lstrip("_"), common_text)
common_text = '"""Helpers shared by the command modules."""\n\n' \
    + import_block(common_text, {h.lstrip("_") for h in common_helpers} | set(common_helpers), "common") \
    + common_text
ast.parse(common_text)

INIT = '''\
"""
The commands of pymux: one function each, in one module each.

A module declares what its command takes with argparse in
`register`, and runs as one function that takes the server and the
parsed arguments. argparse parses with the tree; the shell completes
through it with argcomplete, and the command bar of a client
completes through the same tree in process. Lillecarl/pymux#307.
"""

import argparse
import inspect
import shlex
from importlib import import_module
from typing import TYPE_CHECKING, List

from pymux.commands.aliases import ALIASES
from pymux.enums import Woke
from pymux.log import logger

if TYPE_CHECKING:
    from pymux.main import Pymux

__all__ = [
    "CommandException",
    "add_command",
    "add_commands_to",
    "call_command_handler",
    "handle_command",
    "the_parser",
]

#: One module per command, in the order the commands were written.
MODULES = %(modules)s


class CommandException(Exception):
    "When raised from a command handler, this message will be shown."

    def __init__(self, message: str) -> None:
        self.message = message


class BadLine(Exception):
    "What a parser says about a line it cannot read."

    def __init__(self, message: str) -> None:
        self.message = message


class CommandParser(argparse.ArgumentParser):
    "An argparse parser that raises instead of exiting."

    def error(self, message: str) -> None:
        raise BadLine(message)


def add_command(subparsers, handler, *, name=None, aliases=()):
    """
    The parser of one command: named after its handler, described by
    the first line of its docstring.
    """
    if name is None:
        name = handler.__name__.replace("_", "-")
    parser = subparsers.add_parser(
        name,
        aliases=list(aliases),
        help=(inspect.getdoc(handler) or "").partition("\\n")[0],
        # `-h` is an option of `split-window`, and no command answers
        # a help flag on its own: the help of the command bar and of
        # the shell come from this tree, not from a `-h`.
        add_help=False,
    )
    parser.set_defaults(_handler=handler)
    return parser


def add_commands_to(subparsers):
    """
    Mount every command of the tree on a subparsers action.

    The shell completes the command line of pymux through one parser
    that holds the options of the entry point and every command under
    it. This is what fills the tree under it. It parses nothing on
    its own.
    """
    for name in MODULES:
        import_module("." + name, __name__).register(subparsers)


_the_parser = None


def the_parser():
    """
    The parser of the whole command line: every command under one
    subparsers action. Built once, on first use.
    """
    global _the_parser
    if _the_parser is None:
        parser = CommandParser(prog="pymux", add_help=False, allow_abbrev=False)
        subparsers = parser.add_subparsers(metavar="COMMAND", parser_class=CommandParser)
        add_commands_to(subparsers)
        _the_parser = (parser, subparsers)
    return _the_parser


def handle_command(pymux: "Pymux", input_string: str) -> None:
    """
    Handle command.

    Like tmux, several commands can be given at once, separated by an
    unquoted semicolon. E.g. `send-keys -t %%5 -R ; clear-history -t %%5`.
    """
    input_string = input_string.strip()
    logger.debug("handle command: %%s", input_string)

    if input_string and not input_string.startswith("#"):  # Ignore comments.
        try:
            parts = shlex.split(input_string)
        except ValueError as e:
            # E.g. missing closing quote.
            pymux.show_message("Invalid command %%s: %%s" %% (input_string, e))
        else:
            # Split into separate commands on bare ';' tokens.
            # (Exception: for bind-key/unbind-key, a ';' can be the name of
            # the key that is bound. Like tmux, we don't split there.)
            no_semicolon_split = parts[0] in ("bind-key", "unbind-key")
            commands: List[List[str]] = [[]]
            for part in parts:
                if part == ";" and not no_semicolon_split:
                    commands.append([])
                else:
                    commands[-1].append(part)

            for args in commands:
                if args:
                    call_command_handler(args[0], pymux, args[1:])


def call_command_handler(command: str, pymux: "Pymux", arguments: List[str]) -> None:
    """
    Execute one command, given its words.
    """
    # Resolve aliases.
    command = ALIASES.get(command, command)

    _parser, subparsers = the_parser()
    parser = subparsers.choices.get(command)
    if parser is None:
        pymux.show_message("Invalid command: %%s" %% (command,))
        pymux.add_command_error("pymux: invalid command: %%s" %% (command,))
        return

    try:
        namespace = parser.parse_args(list(arguments))
    except BadLine as e:
        usage = parser.format_usage()[len("usage: "):].rstrip()
        message = "%%s (%%s)" %% (e.message, usage)
        pymux.show_message(message)
        pymux.add_command_error("pymux: %%s" %% (message,))
        return

    try:
        namespace._handler(pymux, namespace)
    except CommandException as e:
        pymux.show_message(e.message)
        pymux.add_command_error("pymux: %%s" %% (e.message,))
        return

    pymux.invalidate(Woke.COMMAND_RAN %% command)
''' % {"modules": repr([c for c in emitted])}

COMPLETER = '''\
"""
What completes a command as it is typed: argcomplete, in process.

argcomplete completes a command line for a shell by parsing the line
against the parser tree. The same move works in process: the bar
hands over the line and the cursor, argcomplete hands back the words
and their help, and nothing leaves the process. The values that only
the running server knows -- the options, the words an option takes,
the layout names, the keys -- are attached to their arguments below,
by command and dest. Lillecarl/pymux#307.
"""

from functools import partial

import argcomplete
from argcomplete.completers import SuppressCompleter
from argcomplete.lexers import split_line
from prompt_toolkit.completion import Completer, Completion
from prompt_toolkit.document import Document

from pymux.arrangement import LayoutTypes
from pymux.commands import the_parser
from pymux.commands.aliases import ALIASES
from pymux.key_spelling import KeyCompleter

__all__ = ["create_command_completer", "stop_shlex_comments"]


def stop_shlex_comments() -> None:
    """
    Stop argcomplete reading a `#` as the start of a comment.

    A command line is not a script, and no part of one is a comment.
    argcomplete lexes the line with a vendored `shlex` whose
    `commenters` is `#`, so everything from the first `#` is dropped,
    and `pymux list-panes -F "#{pane_id}"<TAB>` completed an empty
    word. No shell reads it that way: bash treats `#` as a comment
    only at the start of a word, and `#` is in no `COMP_WORDBREAKS`.

    The fix upstream is one line in `split_line`, and until it is
    there, every program that completes a format string has to install
    this correction for itself. The command bar lexes through
    `split_line` too, so the completer module installs it on import.
    """
    from argcomplete.packages import _shlex

    class _Uncommented(_shlex.shlex):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.commenters = ""

    # `lexers.py` binds this same module object, so the change reaches it.
    _shlex.shlex = _Uncommented


stop_shlex_comments()


def _keys(pymux, prefix, **_):
    """
    The key names for `bind-key` and `compose-key`.

    Both read a chord as well as a tmux name, so both offer the chord:
    a list of the older spelling beside a command that takes either is a
    person never finding out about ctrl+Home. Lillecarl/pymux#234.

    Not the prefix. `bind-key` says whether a binding needs it with
    `-n`, and `send-keys` sends to a pane, where `send-prefix` is the
    command that sends the prefix on. Neither takes it as part of a key.
    """
    completer = KeyCompleter(offer_the_prefix=False)
    return [c.text for c in completer.get_completions(Document(prefix), None)]


def _session_option_names(pymux, **_):
    return sorted(pymux.options)


def _window_option_names(pymux, **_):
    return sorted(pymux.window_options)


def _option_values(pymux, parsed_args, **_):
    option = pymux.options.get(parsed_args.option)
    return sorted(option.get_all_values(pymux)) if option else []


def _window_option_values(pymux, parsed_args, **_):
    option = pymux.window_options.get(parsed_args.option)
    return sorted(option.get_all_values(pymux)) if option else []


def _layout_names(pymux, **_):
    return sorted(t.value for t in LayoutTypes)


def _bound_command(pymux, prefix, parsed_args, **_):
    """
    The command a `bind-key` binding runs, and its arguments: the same
    question again, one word further in. The words already given land
    in `parsed_args.arguments`, and the nested finder reads the line
    they make against the whole tree.
    """
    parser, _subparsers = the_parser()
    nested = argcomplete.CompletionFinder(
        parser, append_space=False, default_completer=SuppressCompleter()
    )
    matches = nested._get_completions(["pymux", *parsed_args.arguments], prefix, "", None)
    meta = nested.get_display_completions()
    return {m: meta.get(m, "") for m in matches}


def _send_keys_names(pymux, prefix, parsed_args, **_):
    "The keys are names while they are the first thing, and no `-l` says they are text."
    if parsed_args.keys or parsed_args.l:
        return []
    return _keys(pymux, prefix)


#: What completes a value, by the command and the dest of the argument.
_VALUE_COMPLETERS = {
    ("set-option", "option"): _session_option_names,
    ("set-option", "value"): _option_values,
    ("set-window-option", "option"): _window_option_names,
    ("set-window-option", "value"): _window_option_values,
    ("select-layout", "layout_type"): _layout_names,
    ("compose-key", "default"): _keys,
    ("bind-key", "key"): _keys,
    ("bind-key", "arguments"): _bound_command,
    ("send-keys", "keys"): _send_keys_names,
}


def _command_help(name, subparsers):
    "The help of one command, which argparse records on a pseudo action."
    for action in subparsers._choices_actions:
        if action.metavar == name:
            return action.help or ""
    return ""


class CommandCompleter(Completer):
    """
    The completer of the command bar.
    """

    def __init__(self, pymux):
        self._pymux = pymux

    def get_completions(self, document, complete_event):
        parser, subparsers = the_parser()
        finder = argcomplete.CompletionFinder(
            parser, append_space=False, default_completer=SuppressCompleter()
        )
        text = document.text_before_cursor
        prequote, prefix, _suffix, words, wordbreak = split_line(text, len(text))
        matches = finder._get_completions(["pymux"] + words, prefix, prequote, wordbreak)
        meta = finder.get_display_completions()

        if not words:
            names = [m for m in matches if not m.startswith("-")]
            if not names:
                # No full name matches: the aliases, spelling the name
                # they run, and what that does.
                for alias in ALIASES:
                    if alias.startswith(prefix):
                        full = ALIASES[alias]
                        yield Completion(
                            full[len(prefix):],
                            start_position=-len(prefix),
                            display="%s (%s)" % (alias, full),
                            display_meta=_command_help(full, subparsers),
                        )
                return

        for m in matches:
            yield Completion(
                m[len(prefix):], start_position=-len(prefix), display_meta=meta.get(m, "")
            )


def create_command_completer(pymux):
    """
    The completer of the command bar, with the completers of the
    values attached to the arguments they complete.
    """
    _parser, subparsers = the_parser()
    for name, parser in subparsers.choices.items():
        for action in parser._actions:
            fn = _VALUE_COMPLETERS.get((name, action.dest))
            if fn is not None:
                action.completer = partial(fn, pymux)
    return CommandCompleter(pymux)
'''

pyedit.write(ROOT + "/common.py", common_text)
for name, mt in emitted.items():
    pyedit.write(ROOT + "/" + name + ".py", mt)
pyedit.write(ROOT + "/__init__.py", INIT)
pyedit.write(ROOT + "/completer.py", COMPLETER)
pyedit.delete(SRC)

print("modules:", len(emitted))
print("common helpers:", len(common_helpers), sorted(h.lstrip("_") for h in common_helpers))
print("local helpers:", sorted(h for h in set(helpers) - common_helpers))
print("ERRORS:" if errors else "no errors")
for e in errors:
    print("  ", e)
