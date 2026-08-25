"""Deciding whether a command line was meant for the model.

Kept pure and kept away from xonsh so the rules can be read -- and tested --
without a shell. `integration` is what hooks this up to
`events.on_transform_command`.

The prefix is `:` by default for two reasons. It cannot collide: `:` is not a
xonsh alias and no filesystem path can begin with one, so unlike a `/` prefix
there is no "is this actually an absolute path" rule to get wrong. And it is
what Helix uses to open its command palette, which is the editor this shell is
already pretending to be.
"""

from __future__ import annotations

from typing import NamedTuple

#: Default prefix. `$XONTRIB_PAI_PREFIX` overrides it -- `,` is the other
#: sensible pick, being unshifted on most layouts.
PREFIX = ":"


class Request(NamedTuple):
    """One parsed line. `command` is empty for free-form prose."""

    command: str
    text: str


def addressed(line: str, prefix: str = PREFIX) -> bool:
    """Is this line being written to the model?

    Deliberately broader than `parse`, and the two are answering different
    questions. `parse` decides what to *do* with a finished line, and refuses a
    bare prefix because `:` alone is a typo rather than a request for an empty
    prompt. This decides what a line *is*, while it is still being typed -- and
    a `:` that has just been pressed is already on its way to being a question.
    """
    return bool(prefix) and line.startswith(prefix)


def parse(line: str, prefix: str = PREFIX) -> Request | None:
    """Split a command line, or `None` if it was not addressed to the model.

    Two shapes, distinguished by what follows the prefix:

        : what is my ip        ->  Request("", "what is my ip")
        :model deepseek        ->  Request("model", "deepseek")

    A space means the rest is prose, so it is never inspected further -- which
    is the whole point of doing this before xonsh parses anything. Apostrophes,
    globs and pipes reach the model verbatim instead of becoming a syntax error
    or, worse, being quietly expanded.
    """
    if not addressed(line, prefix):
        return None
    rest = line[len(prefix) :]
    if not rest.strip():
        # A bare prefix is a typo, not a request for an empty prompt.
        return None
    if rest[0].isspace():
        return Request("", rest.strip())
    head, _, tail = rest.partition(" ")
    return Request(head, tail.strip())
