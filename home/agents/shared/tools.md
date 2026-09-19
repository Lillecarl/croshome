## Editing and iterating

Edit files with the file-editing tools. Never rewrite a source file by piping a
Python or sed program into the shell: a `python3 - <<'PY'` block doing
`src.replace(...)` leaves no diff to read, does not fail when the anchor text is
wrong, and leaves nothing anyone can run again.

Size is not the exception. A one-line `sed -i` has all three faults a forty-line
script has: no diff, silence on a wrong anchor, nothing to re-run. Short buys
nothing here.

Claude Code's auto mode carries no steer toward the shell here:
`env.CLAUDE_CODE_THRIFTY_SONIC = "0"` in `home/agents.nix` drops that paragraph
from the prompt. Seeing it anyway means the setting did not reach the session —
say so, and follow this file. **The same holds for any other harness that
prefers the shell for file changes.**

A PreToolUse hook refuses the Python case, so that much is a block and not
advice. It fires only on inline Python that writes -- `-c` or a heredoc.
Running a `.py` file in the repository and a read-only one-liner are untouched.
`I_AM_REALLY_STUPID=1` in front of the command allows it anyway: the name is
the whole review process, and it stays in the transcript. **No hook covers
`sed`**, so that one is on you.

**`pyedit` is that script, done properly.** Same job, and better at it: edits
staged in memory, shown as dry-run diffs, written only on `--apply`, and a bad
anchor fails instead of matching nothing quietly. Reach for it whenever the
edit is more than the file-editing tools want -- several files at once, one
file in many places, a rename across a tree.

Do not guess at its interface. The package ships a `pyedit` skill, so a harness
that loads skills already has it — load that. Without one, `pyedit skill`
prints the same document.

Iterate through the project's own entry point, not through a loop you build in
the shell. Give that entry point a knob if it needs one: impure Nix with
`builtins.getEnv` gives near-total control of a test invocation, so add the
variable to the derivation and use it. A private `nix develop --command` loop
reproduces the sandbox badly and proves less.

Bring an external tool or test suite in as a Nix package, in the check inputs,
unless the work has to edit that suite.

Set the shape up right early. One step now, saved on every iteration after.

## Keep the whole output

`tee` before you narrow. Every filter -- `grep`, `head`, `jq`, `tail -1`,
`--quiet` -- throws away the part that answers the next question, and a re-run
does not reproduce the moment.

```sh
nix build ... 2>&1 | tee $SCRATCH/build.log | grep -E "error|warning"
```

Write the file to the scratchpad, name it after what made it, and give me the
path when you report what the filter found. The error you grep for is rarely
the error that matters; the line above it usually is.

Same for a monitor or a background command: its output file already holds
everything, so read that file instead of re-running the command.

## Waiting on a process

Never `pgrep -f`, `pkill -f` or `ps | grep`. Your command runs inside a wrapper
shell whose argv holds the pattern, so the pattern always matches that shell.
Measured: `pgrep -af zzzUniquePatternZzz` printed the wrapper's own line. A
`while pgrep -f X` loop therefore never ends, and the tool call hangs until its
timeout.

Instead:

- work you started -- `run_in_background: true` for one completion, a monitor
  for repeated events. Both notify you. Do not poll and do not sleep.
- a pid you hold -- `kill -0 $pid`.
- a process you did not start -- `pidof <exe>` (exact name, no self-match), or
  better, the state file, socket or API that answers the real question.

## Timeouts

Pick the number from what the command takes. Most finish in seconds, and every
harness default is already longer than that.

**A timeout that fires is a result.** It says the command did not finish.
Raising it and running again buys that same answer more slowly, and every
iteration after pays the new number. So troubleshooting moves a timeout *down*:
a failure at 10s carries what a failure at 600s carries, and carries it sooner.

Raise one only on evidence -- you watched the output advance right up to the
cut, so more time plainly finishes it. "It might need longer" is not evidence,
and neither is having been cut off once.

Work that really does run for minutes gets no timeout at all. Background it and
read the log. A long timeout blocks the session; a background job does not.

## Building with Nix

Use the `nix` subcommands, never the older separate binaries. Spell flags
long: `--file`, not `-f`.

| use | not |
| --- | --- |
| `nix build --file . <attr>` | `nix-build -A <attr>` |
| `nix eval --file . <attr>` | `nix-instantiate --eval -A <attr>` |
| `nix run --file . <attr>` | — |
| `nix shell --file . <attr>` | `nix-env -i` |
| `nix develop --file .` | `nix-shell` |
| `nix profile` | `nix-env` |
| `nix store gc` | `nix-collect-garbage` |

`nix-env -p /nix/var/nix/profiles/system --set` is the exception: the system
profile has no `nix profile` equivalent that keeps generations the same way.

The invocation form is `nix <subcommand> <options> --file <path> <attrpath>`.
Non-flake, always. Two skills carry the rest, and they are worth loading rather
than guessing: **nix** before a command you are unsure of, **nix-language**
before editing a `.nix` file.

## Reading nixpkgs

`/etc/nixpkgs` is the pinned nixpkgs these machines build from, and `NIX_PATH`
points at it. Read it instead of guessing at an option, a setup hook or the
shape of a package, and instead of cloning nixpkgs somewhere — a clone drifts
from the tree that actually builds this system.

```sh
grep -rl pytestCheckHook /etc/nixpkgs/pkgs/development/python-modules | head
grep -rn "buildPythonApplication" /etc/nixpkgs/doc/languages-frameworks/python.section.md
```

It is a store path, so it is read-only and it moves when the lock moves.
