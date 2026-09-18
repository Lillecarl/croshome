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

Stop and ask, through the question tool — `AskUserQuestion` in Claude Code,
`question` in opencode. It puts multiple-choice options to me and blocks for
the answer. Two options, correct route first:

    correct route:  cost, benefit
    workaround:     cost, benefit

Put each route's cost and benefit in that option's description. Mark the one
you recommend `(Recommended)` at the end of its label.

No exception, and no size threshold. A one-line pin needs the question as much
as a rewrite does. This holds even when it stops you working autonomously:
losing the autonomy costs one round trip, and taking the workaround unasked
costs me the undo plus the unreported bug.

Investigating a workaround is fine. The rule bites at implementing, not at
looking.

Why this one is a rule: a workaround reported afterwards reads as progress, so
I spend my own effort undoing a decision nobody offered me, and the real bug
stays unreported behind a gone symptom.
