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
