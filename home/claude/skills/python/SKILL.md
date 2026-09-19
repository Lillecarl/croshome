---
name: python
description: House standards for Python in Lillecarl's own projects — async by default, anyio over bare asyncio, real type annotations, `from __future__ import annotations` and `if TYPE_CHECKING:`, named values (StrEnum, Literal, Final) over scattered literals. Load before writing or editing Python in a repository he maintains, or when starting a new one. Deliberately does NOT apply to external projects; see Scope.
---

# Python standards

## Scope — check this first

These are house rules for **Lillecarl's own projects and new projects started
here**. They are not general Python advice and must not be imposed on code
somebody else maintains.

In scope when any of these holds:

- the git remote owner is `Lillecarl` or `nixidae`;
- the repository carries its own `AGENTS.md` or `CLAUDE.md` written in the
  first person by the user;
- the project is new, and being started in this session.

Out of scope, and the rules below do not apply:

- a dependency or upstream project cloned to read — `~/Code/<repo>` holds both
  kinds, so the directory is not the signal, the remote is;
- a patch or pull request aimed at someone else's repository;
- vendored third-party code inside one of his repositories.

**Out of scope means match the surrounding code.** A pull request that
rewrites a maintainer's idiom to this one gets rejected on style and wastes
the work. If the repository has a linter config, that config wins over this
file.

A project in scope may still have its own `AGENTS.md` with stricter or
different rules. That file wins; this one is the floor.

## Async

**Prefer async when there is a choice.** A new service, client or IO-bound
library starts async. Sync is right for a script that does one thing and
exits, and for a CPU-bound path.

**Prefer `anyio` over bare `asyncio`.** It runs on asyncio and on trio, its
cancellation semantics are the sane ones, and structured concurrency is the
default rather than something you assemble.

```python
async with anyio.create_task_group() as tg:
    tg.start_soon(worker, arg)
```

The task group owns its tasks: it waits for them, and it cancels them if one
fails. That removes the whole class of bug where a bare
`asyncio.create_task(...)` result is not held anywhere and the garbage
collector eats the task mid-flight.

Take the primitive from `anyio` too, not the `asyncio` one beside it:
`anyio.Lock`, `anyio.Event`, `anyio.Semaphore`, the memory object streams,
`anyio.fail_after`, `anyio.move_on_after`, `anyio.create_task_group`,
`anyio.open_process`, `anyio.to_thread`, `anyio.from_thread.BlockingPortal`,
and **`anyio.Path`**, which is the one most often missed.
Mixing the two families is where cancellation stops behaving. ruff's `TID251`
banned-api rule enforces this per project, and a rule in the linter beats a
rule in prose.

On bare `asyncio`, where you have no choice:

- `asyncio.TaskGroup` over `gather` or loose `create_task`.
- Never `asyncio.get_event_loop()`. Inside a coroutine it is
  `asyncio.get_running_loop()`; for a timestamp it is `time.monotonic()`.
- A task from `create_task` that must outlive the call needs a strong
  reference held somewhere real.

## Typing

**Annotate, and annotate with the types, not with strings.**

```python
from __future__ import annotations   # first import in every module

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .store import Session, Store


def connect(store: Store) -> Session:
    return store.session()
```

`from __future__ import annotations` makes every annotation lazy, which is why
`Store` above needs no quotes even though it is only imported for type
checking. Writing `store: "Store"` with that import present is redundant, and
without it you should add the import rather than quote the name.

`if TYPE_CHECKING:` is for type-only imports — the ones that would be a
circular import or a needless runtime cost. It goes last among the imports,
and it holds nothing the program needs at runtime.

## Named values over scattered literals

A value with a meaning gets a name at the point that owns the meaning, and
everything else imports it. Lightest thing that carries it:

- **`enum.StrEnum`** (3.11+) for a set that crosses a boundary — config, JSON,
  CLI flags, storage. Members are plain strings, so they serialize and compare
  without ceremony. On an older runtime, `class X(str, Enum)`.
- **`enum.Enum`** for a set that never needs to read as a string or a number —
  internal kinds, states, priorities. Members are opaque objects: no accidental
  comparison with ints, no accidental serialization.
- **`enum.IntEnum`** when the value is genuinely a number — bit flags, C or
  struct interop, exit codes, a column stored as an int. It compares equal to
  plain ints, which is the interop wanted and the type safety lost:
  `QUEUED == 0` is true.
- **`typing.Literal`** when the set exists only for the type checker — three
  legal spellings for one parameter, no behavior attached.
- **`NAME: Final = ...`** for a single shared constant.

`auto()` numbers members by declaration order, so reordering members
renumbers everything ever persisted through it. Spell values out whenever a
number is stored or exchanged; `auto()` only where nothing can see the value.

```python
class JobState(StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    FAILED = "failed"
```

The win is not the comparison line — it is that adding or renaming a member is
one edit where the meaning lives, instead of a repo-wide grep and the typos
that survive it. Prefer these over scattering raw strings and ints, and over
inventing a third spelling of the same value in a second file.

Tests repeat literals freely; that is what they are for. Promote a constant
out of test code only when the same literal keeps coming back in many places.

## A few more that keep coming up

- **All imports at the top**, or inside `if TYPE_CHECKING:`. An import inside a
  function is for breaking a real import cycle, and a cycle is usually better
  fixed by moving the shared type to a neutral module.
- **No `assert` outside `tests/`.** `python -O` removes it. Runtime validation
  is `if not cond: raise RuntimeError(...)`.
- **No silent `except Exception: pass`.** Log it, or use
  `contextlib.suppress(...)` with a comment saying why it is expected.
- **`pathlib.Path` for paths, `anyio.Path` in async code.** Every method that
  touches the filesystem is awaitable — `read_text`, `exists`, `mkdir` — while
  the pure-path parts (`.parent`, `.parts`, `/`) stay synchronous. A
  `pathlib.Path` inside a coroutine is a blocking call wearing a familiar name.

  It is **not** a `pathlib.Path` subclass: `isinstance(p, pathlib.Path)` is
  `False`, so a signature annotated `pathlib.Path` rejects it. It does satisfy
  `os.PathLike`, so `open(p)` and anything taking a path-like still works.
  Annotate with `anyio.Path`, and convert to `str` as late as you can.

---

This file is short on purpose and meant to grow. Add a rule when a real
mistake shows it is missing, not in anticipation. `~/Code/nixidae/*/AGENTS.md`
holds the per-project rules these were generalised from.
