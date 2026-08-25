## Compaction

**Compact yourself. Do not ask.** The wrapty plugin gives you a `compact`
tool and a usage figure after each turn, so you know the number and the user
does not. The tool refuses when the context is too empty to be worth
compacting, so a call that is too early costs an error and nothing else.

Compact at a **boundary**, not at a threshold. A boundary is a point where
losing the detail costs nothing:

- The work is committed and pushed, and the next piece starts clean.
- The conversation turns to a new topic. The old detail is dead weight.
- A large piece is about to start and the context is half gone. Running out
  in the middle is worse than compacting before.

Do not compact in the middle of a debugging chain, with uncommitted work, or
while holding a measurement you have not written down yet. Write it to the
repository, to an issue or to memory **first**. A compaction that loses the
one number the next step needs has cost more than it saved.

**Keep the instructions short.** A plain `/compact` is fine most of the time:
the summary reads the whole conversation, so it finds the task without help.
Pass instructions only when the next step needs something specific, and keep
them to a line or two -- what we do next, and the one thing that must
survive, such as a path, a number or a decision. Do not write a structured
brief. Long instructions cost more than they save.

Say one line after compacting: what you kept and why now. Do not ask
permission and do not report the percentage on a turn where nothing happened.
