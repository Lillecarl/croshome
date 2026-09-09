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

Prefer `nix build --file . <attribute>` over `nix-build -A <attribute>`.
