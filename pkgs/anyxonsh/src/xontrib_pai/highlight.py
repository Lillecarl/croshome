"""Keeping the Python highlighter off lines that were never Python.

xonsh colours the command line with a Pygments lexer, which is the right thing
to do to a command line. A `: ` request is not one -- it is prose, and prose put
through a Python lexer comes out wrong in the way that is hardest to ignore::

    : what's my ip?

Everything from the apostrophe onwards turns string-coloured, because as far as
the lexer is concerned an unterminated string is exactly what it is looking at.
`is` goes keyword-coloured a few characters earlier. Nothing is broken -- the
line never reaches the parser, `integration` takes it first -- but the colours
say it is about to be, which is a lie told on every question anyone asks.

So a prefixed line is handed back as one unstyled fragment, and the lexer
underneath is never called at all. That is the second half of it: pygments runs
on every keystroke, and a long question is a long line to lex for a result that
was going to be discarded.

The wrapper goes on the `BufferControl` rather than on the `PromptSession`,
because `PromptSession.prompt()` assigns `self.lexer` from its keyword argument
on every prompt -- so anything installed there lasts exactly one line. The
control holds a `DynamicLexer` that reads that attribute back at render time,
which is the thing worth wrapping: whatever xonsh sets, we still delegate to it.
"""

from __future__ import annotations

from collections.abc import Callable

from prompt_toolkit.document import Document
from prompt_toolkit.formatted_text.base import StyleAndTextTuples
from prompt_toolkit.lexers import Lexer

from .prefix import addressed


class Unlexed(Lexer):
    """`inner`, except on lines addressed to the model, which come back plain.

    `prefix` is a callable rather than a string because `$XONTRIB_PAI_PREFIX`
    can be changed by eye, mid-session, and a lexer that had been told the
    prefix once would go on colouring the new one.
    """

    def __init__(self, inner: Lexer, prefix: Callable[[], str]) -> None:
        self.inner = inner
        self.prefix = prefix

    def lex_document(
        self, document: Document
    ) -> Callable[[int], StyleAndTextTuples]:
        if not addressed(document.text, self.prefix()):
            return self.inner.lex_document(document)

        lines = document.lines

        def get_line(lineno: int) -> StyleAndTextTuples:
            try:
                return [("", lines[lineno])]
            except IndexError:
                return []

        return get_line

    def invalidation_hash(self):
        """What `BufferControl` caches lexed lines against.

        The prefix belongs in here as well as the inner lexer's own hash:
        changing it changes which lines this answers for, and the text a line
        is cached under has not moved.
        """
        return (self.inner.invalidation_hash(), self.prefix())


def install(prompter, prefix: Callable[[], str]) -> bool:
    """Wrap the lexer of `prompter`'s own buffer. False if it was not found.

    Not fatal when it fails: the line still reaches the model, it just looks
    like a broken Python statement on the way. So this reports rather than
    raises -- a shell that will not start is a worse outcome than a shell that
    miscolours one kind of line.

    Idempotent. Loading the xontrib twice must not stack two wrappers, which
    would work but would leave the first one holding a stale prefix.

    It stops at the first match, and that matters: the walk hands back the same
    control more than once, because the window holding the input line hangs off
    the container tree in more than one place. Wrapping "every match" would wrap
    one control twice.
    """
    from prompt_toolkit.layout.controls import BufferControl

    buffer = prompter.default_buffer
    for control in prompter.app.layout.find_all_controls():
        if isinstance(control, BufferControl) and control.buffer is buffer:
            if isinstance(control.lexer, Unlexed):
                control.lexer.prefix = prefix
            else:
                control.lexer = Unlexed(control.lexer, prefix)
            return True
    return False
