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

GitHub issues and pull requests outside `github/Lillecarl` and
`github/nixidae` always need approval first, no matter how obvious the
report feels. Inside those two the rules above apply unchanged. A bug
found elsewhere is reported, never filed: evidence in the reply, filing
left to me.

An issue or PR where a human other than User takes part is a conversation with
that person, in User's name. Inside `github/Lillecarl` and `github/nixidae`
too: before any comment, close, reopen, label, edit or review there, tell User
what and why, and wait. Outsider test: `author_association` on the issue and
each comment is `NONE`, `CONTRIBUTOR` or `FIRST_TIME_CONTRIBUTOR`. `gh api
repos/O/R/issues/N` and `.../issues/N/comments` carry it; `gh issue view
--json` lacks it for the issue itself.

Phabricator/Phorge tasks (Dynamist board): Agent never changes a task's
status — no resolve, close, wontfix or invalid, on any task. Finished work:
move to the Done column, comment the proof; status stays open. The team closes
Done tasks at standup, and Done is how the team sees the work. Duplicate or
invalid: comment why, tell User. The phabfive skill's `--status=resolved`
examples are tool syntax, not permission.

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
