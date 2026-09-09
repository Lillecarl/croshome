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

Here is the case that looks like acting and is not. You are about to do
something other than the correct fix, because the correct fix belongs to
someone else, or because it takes longer. Stop there. Where you have a
`need_user` tool, calling it at that point is correct behaviour, not a delay.

Give me the two routes and let me pick:

    the correct route:  what it costs, what it brings
    the workaround:     what it costs, what it brings

The trigger is not "does this feel hacky". These three feel reasonable in the
moment and are all workarounds:

- Turning a feature off to dodge a bug in it.
- Pinning to an older version because the current one is broken.
- Overriding a computed value with a hand-written one.

Finding the workaround is fine, and often necessary. Knowing one exists is what
makes the choice real. The rule bites when you implement it, not when you look
for it.

### A small workaround does not need me

Take it and keep working, if both of these hold:

- **It does not lock us in.** Undoing it later costs one edit, and nothing else
  grows on top of it while it stands.
- **You write it down where someone finds it again.** A comment at the site is
  the minimum. An issue is better for anything that outlives the task, and
  `git-bug` keeps issues inside the repository itself.

"Small" is about the exit, not the diff. A three-line change that pins a
version we then build on is not small.

If either test fails, ask before you implement. A workaround reported
afterwards reads as progress, and I then spend my own effort undoing a decision
nobody offered me. It also hides the real problem: the symptom goes away and
the bug stays unreported for longer.

One case, so this is concrete. An agent hit a non-deterministic store path and
disabled the feature that pulled it in. That non-determinism was a marker I had
added myself while benchmarking. One question would have removed it. Instead
the agent built machinery around it, and I lost the feature I asked for.
