"""History search: the source of the flowing alternatives box.

`/` in normal mode turns the command line itself into the query field and
opens prompt_toolkit's completion menu under it -- one box of alternatives
that re-filters on every keystroke. This module is the completer that feeds
that box; `integration.py` owns the keys and the open/close lifecycle.

Ranking mirrors what a person expects from recent-first history: exact-prefix
matches on top (most recent first), then substring matches, also most recent
first. Nothing here ranks by fuzziness -- history is small, commands are
memorisable, and "starts with what I typed" is nearly always the intent.
"""

from __future__ import annotations

from prompt_toolkit.completion import Completer, Completion

#: Enough. Ten thousand commands at a substring scan per keystroke is well
#: under a millisecond; a cap exists so a runaway history file cannot make the
#: box feel heavy.
_LIMIT = 5000


def _entry_input(entry) -> str:
    """The command text of one history entry, whatever shape it arrives in.

    Some xonsh history backends hand out plain dicts, others objects with
    attribute access; ask both ways rather than assume.
    """
    if isinstance(entry, dict):
        return entry.get("inp") or ""
    return getattr(entry, "inp", None) or ""


def history_entries() -> list[str]:
    """Every distinct command in this shell's history, newest first.

    `all_items` spans every recorded session; plain `items()` is this
    session only, which would make the box look like the shell forgets
    everything between invocations.
    """
    from xonsh.built_ins import XSH

    history = XSH.history
    if history is None:
        return []
    seen: set[str] = set()
    out: list[str] = []
    for entry in history.all_items(newest_first=True):
        cmd = _entry_input(entry).strip()
        if not cmd or cmd in seen:
            continue
        seen.add(cmd)
        out.append(cmd)
        if len(out) >= _LIMIT:
            break
    return out


class HistorySearchCompleter(Completer):
    """Filter `history_entries()` by whatever is in the buffer right now."""

    def __init__(self) -> None:
        self.entries = history_entries()

    def get_completions(self, document, complete_event):  # noqa: ANN001 - ptk signature
        query = document.text.strip().lower()

        if not query:
            # An empty query is still a query: show where you have been,
            # newest first, so `/` <enter> reads as "recent commands".
            yield from (Completion(cmd) for cmd in self.entries[:8])
            return

        prefixes: list[str] = []
        substrings: list[str] = []
        for cmd in self.entries:
            low = cmd.lower()
            if low.startswith(query):
                prefixes.append(cmd)
            elif query in low:
                substrings.append(cmd)
        yield from (Completion(cmd, start_position=-len(document.text)) for cmd in prefixes)
        yield from (
            Completion(cmd, start_position=-len(document.text))
            for cmd in substrings[: max(0, 60 - len(prefixes))]
        )
