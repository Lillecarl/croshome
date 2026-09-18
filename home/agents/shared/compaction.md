## Compaction

**Compact yourself. Do not ask.** Your harness gives you a `compact` tool. It
refuses when the context is too empty to be worth compacting, so a call that
comes too early costs an error and nothing else.

What you are told about usage differs, and you get no say in it. Claude Code
carries a figure every turn, so the number is always in front of you. opencode
tells you nothing until 35%, then adds a pressure note as usage climbs past it.
Below that you are working blind. That is why the boundary below is a
judgement and not a threshold — you cannot wait for a number that may never
arrive.

Compact at a **boundary**, not at a threshold — a point where losing the detail
costs nothing:

- The work is committed and pushed, and the next piece starts clean.
- A new task starts that the context you hold does not serve. Compact before
  you begin it, not partway in. Judge by what the next task needs, not by the
  percentage: a long context the next task reads from is worth keeping, and a
  short one about something else is not.
- A large piece is about to start with the context half gone. Running out
  mid-piece is worse than compacting before.

Never compact in the middle of a debugging chain, with uncommitted work, or
while holding a measurement you have not written down. Write it to the
repository, to an issue or to memory **first**. A compaction that loses the one
number the next step needs costs more than it saved.

**Keep the instructions short**, where the tool takes them at all. A plain
compaction is usually right: the summary reads the whole conversation and finds
the task without help. Pass instructions only when the next step needs
something specific — a line or two, naming what comes next and the one thing
that must survive, such as a path, a number or a decision. Never write a
structured brief.

Say one line after compacting: what you kept, and why now. Do not report the
percentage on a turn where nothing happened.
