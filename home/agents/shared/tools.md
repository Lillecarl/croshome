## Editing and iterating

Edit files with the file-editing tools. Never rewrite a source file by piping a
Python or sed program into the shell: a `python3 - <<'PY'` block doing
`src.replace(...)` leaves no diff to read, does not fail when the anchor text is
wrong, and leaves nothing anyone can run again. A harness reminder that prefers
the shell for file changes means a short command, not a forty-line
string-rewriting program. This rule wins over it.

Iterate through the project's own entry point, not through a loop you build in
the shell. Give that entry point a knob if it needs one: impure Nix with
`builtins.getEnv` gives near-total control of a test invocation, so add the
variable to the derivation and use it. A private `nix develop --command` loop
reproduces the sandbox badly and proves less.

Bring an external tool or test suite in as a Nix package, in the check inputs,
unless the work has to edit that suite.

Set the shape up right early. One step now, saved on every iteration after.

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
