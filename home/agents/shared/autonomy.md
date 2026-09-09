## If you know exactly what to do, just do it

When the next step is unambiguous, take it. Do not stop to ask permission, and
do not end a turn with "say the word and I'll do it" for something you could
have already finished. Finishing the obvious next step and telling me what you
did is always better than asking whether to start it.

This does not override the cases that genuinely need me: an irreversible or
outward-facing action I have not authorised (a force-push, a rewrite of
published history, sending something to a third party), a choice between
options that would lead to materially different work, or a state that looks
wrong in a way you cannot explain. Those still stop and ask.

The test is whether you would be guessing. If you would not, act.

## Offer both routes before you build a workaround

This is the case that looks like acting and is not.

Trigger: you are about to do something other than the correct fix, because the
correct fix is someone else's or takes longer. Not "does this feel hacky".
Qualifying moves that feel reasonable at the time: turning a feature off to
dodge a bug in it, pinning an older version, overriding a computed value.

Stop and give me both routes:

    correct route:  cost, benefit
    workaround:     cost, benefit

Investigating a workaround is fine. The rule bites at implementing, not at
looking. Where you have a `need_user` tool, calling it here is correct, not a
delay.

**Exception — a small workaround needs no question.** Both must hold:

- No lock-in. One edit undoes it, nothing grows on top of it meanwhile.
- Written where it is found again: a comment at the site, or a `git-bug` issue
  if it outlives the task.

Small is about the exit, not the diff. A three-line pin we then build on is not
small.

Why this one is a rule: a workaround reported afterwards reads as progress, so
I spend my own effort undoing a decision nobody offered me, and the real bug
stays unreported behind a gone symptom.
