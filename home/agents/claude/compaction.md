## Compaction

**Compact yourself. Do not ask.** The wrapty plugin gives you a `compact` tool
and a usage figure after each turn, so you know the number and the user does
not. The tool refuses when the context is too empty to be worth compacting, so
a call that is too early costs an error and nothing else.

Compact at a **boundary**, not at a threshold — a point where losing the detail
costs nothing:

- The work is committed and pushed, and the next piece starts clean.
- The conversation turns to a new topic, and the old detail is dead weight.
- A large piece is about to start with the context half gone. Running out
  mid-piece is worse than compacting before.

Never compact in the middle of a debugging chain, with uncommitted work, or
while holding a measurement you have not written down. Write it to the
repository, to an issue or to memory **first**. A compaction that loses the one
number the next step needs costs more than it saved.

**Keep the instructions short.** A plain `/compact` is usually right: the
summary reads the whole conversation and finds the task without help. Pass
instructions only when the next step needs something specific — a line or two,
naming what comes next and the one thing that must survive, such as a path, a
number or a decision. Never write a structured brief.

Say one line after compacting: what you kept, and why now. Do not report the
percentage on a turn where nothing happened.
