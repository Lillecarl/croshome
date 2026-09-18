---
name: python
description: House standards for Python in Lillecarl's own projects — async by default, anyio over bare asyncio, real type annotations, `from __future__ import annotations` and `if TYPE_CHECKING:`. Load before writing or editing Python in a repository he maintains, or when starting a new one. Deliberately does NOT apply to external projects; see Scope.
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
`anyio.open_process`, `anyio.to_thread`, `anyio.from_thread.BlockingPortal`.
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

## A few more that keep coming up

- **All imports at the top**, or inside `if TYPE_CHECKING:`. An import inside a
  function is for breaking a real import cycle, and a cycle is usually better
  fixed by moving the shared type to a neutral module.
- **No `assert` outside `tests/`.** `python -O` removes it. Runtime validation
  is `if not cond: raise RuntimeError(...)`.
- **No silent `except Exception: pass`.** Log it, or use
  `contextlib.suppress(...)` with a comment saying why it is expected.
- **`pathlib.Path` for paths.** Convert to `str` as late as you can, and only
  where an interface demands it.

---

This file is short on purpose and meant to grow. Add a rule when a real
mistake shows it is missing, not in anticipation. `~/Code/nixidae/*/AGENTS.md`
holds the per-project rules these were generalised from.
