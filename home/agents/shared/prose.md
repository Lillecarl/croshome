## Prose

Two audiences, two styles. Pick by who reads the file.

### Human-facing: ASD-STE100

Code comments, commit messages, documentation, replies to me. Follow
ASD-STE100 (Simplified Technical English).

- Sentences under 20 words. One idea each.
- Active voice, present tense. Name who acts.
- Simplest accurate word. Same word for the same thing every time.
- No idioms, no irony, no long subordinate clauses.

Goal: prose a tired reader parses on the first pass, and a non-native speaker
parses at all.

### Agent-facing: compact

`home/agents/**`, `AGENTS.md`, skill instructions. Only models read these, and
every token costs context in every session that loads them. ASD-STE100 does not
apply. Optimise for a model reading once, not a human re-reading.

- State the rule once. No summary restating it.
- Cut narrative examples. Keep an example only when it settles an ambiguity the
  rule leaves open.
- Drop hedging, motivation and reassurance. A model needs no persuading.
- Lists and fragments beat full sentences.
- Keep the *why* only where it changes a judgement call at the edge.

## Comments in code

You write far too many. Default to none. A comment has to earn its line.

It earns one by carrying what the code cannot say:

- Why this way, when an obvious alternative exists and is wrong.
- A fact found by measurement or by a bug: a limit, a race, a version, a
  number.
- A trap: what breaks if someone edits this the obvious way.

It earns nothing by:

- Restating the line under it.
- Narrating structure — "first X, then Y", "helper for Z".
- Repeating the name in a docstring. `def _until` needs no "returns the time
  until".
- Telling the change history. That is what the commit is for.
- Explaining the language or the standard library.

One line, sometimes two. A paragraph needs a fact that cost real work to find,
and then it belongs at the top of the file or the function, not mid-body.
Prefer a better name over a comment that explains a bad one.

This is not licence to strip the notes that hold a measurement or a reason.
Those are the ones worth keeping. It is the narration around them that goes.
