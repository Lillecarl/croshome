## Editing and iterating

Edit files with the file-editing tools. Never rewrite a source file by piping
a Python or sed program into the shell. A `python3 - <<'PY'` block that does
`src.replace(...)` has no diff to read, no failure when the anchor text is
wrong, and nothing left behind that anyone can run again. If a harness
reminder tells you to prefer the shell for file changes, it means a short
command, not a forty-line string-rewriting program, and this rule wins over it.

Iterate through the project's own entry point, not through a loop you build in
the shell. Give that entry point a knob if it needs one. Impure Nix with
`builtins.getEnv` allows practically full control of a test invocation, so add
the variable to the derivation and use it. A private `nix develop --command`
loop repeats the sandbox badly and proves less.

Bring an external tool or test suite in as a Nix package, in the check inputs.
Do that unless the work has to edit that suite.

Set the shape up right early. It costs one step now and saves every iteration
after it.

## Building with Nix

Prefer `nix build --file . <attribute>` over `nix-build -A <attribute>`.
