---
name: nix-language
description: The Nix language itself — syntax and semantics that models reliably get wrong. Use before writing or editing any .nix file, and when a Nix expression fails to parse or evaluates to something unexpected. Covers attribute key quoting, the shallow // merge, with scoping, list syntax, paths versus strings, string escaping, function arguments, the lib.optional family, lib.getExe/lib.getExe' for package binaries, Python package-set scoping, project layout (default.nix first, flake.nix only a wrapper) and nixpkgs package conventions (finalAttrs, filesets, callPackage). Ships a tested template project in demo/ — read it before starting or restructuring a Nix project. For running nix commands, use the nix skill.
---

# The Nix language

Every claim here was checked with `nix eval` against nixpkgs 26.11. The output
shown is the real output.

## Quoting attribute keys

An identifier is `[a-zA-Z_][a-zA-Z0-9_'-]*`. So:

**Dashes need no quotes.** They are ordinary identifier characters, anywhere
but the first position.

```nix
{ foo-bar = 1; }.foo-bar   # => 1
{ a-b-c = 1; }.a-b-c       # => 1
```

Writing `{ "foo-bar" = 1; }` is noise. Do not add quotes because a key has a
dash in it.

**A leading digit needs quotes.** An identifier cannot start with one.

```nix
{ 2foo = 1; }              # error: syntax error, unexpected integer
{ "2foo" = 1; }."2foo"     # => 1
```

Same for a key that is entirely digits, and for one holding a dot, a space or
any other non-identifier character. A dot inside quotes stays one key:
`{ "a.b" = 1; }` has a single key, not a nested attrset.

**A keyword needs quotes**, to define and to select: `{ "rec" = 1; }."rec"`.
Bare `rec`, `let`, `in`, `if`, `with`, `inherit`, `assert` are syntax errors
as keys. `or` is the exception: `{ or = 1; }.or` works.

## `//` is a shallow merge

It replaces a key outright. It does not merge into it.

```nix
{ a = { x = 1; y = 2; }; } // { a = { x = 9; }; }
# => { a = { x = 9; }; }        y is gone
```

Use `lib.recursiveUpdate` when you mean to merge nested attrsets. In a NixOS or
home-manager module you almost never want either — the module system merges
`config` for you, and `//` there defeats it.

## `with` does not shadow

A `with` brings names into scope *below* every enclosing binding. A `let` or a
function argument wins over it.

```nix
let x = 1; in with { x = 2; }; x    # => 1
```

This is the reverse of what most people expect, and it fails silently: the
value is simply the other one. `with pkgs;` over a long list is where it bites.
Prefer `inherit (pkgs) a b c;` or a qualified `pkgs.a`, and keep `with` to
short, obvious spans.

## Lists have no commas

```nix
[ 1 2 3 ]        # correct
[ 1, 2 ]         # error: syntax error, unexpected ','
```

Elements are whitespace-separated. A function call in a list needs parentheses,
or its arguments become separate elements: `[ (f x) ]`, never `[ f x ]`, which
is a two-element list.

## `/` is division only with spaces

```nix
6 / 2     # => 3
6/2       # => a relative path, ./6/2
```

`x/y` with no spaces is path syntax. This parses cleanly and gives you a path
where you wanted a number, so the error surfaces far from the cause.

## Paths and strings are different types

```nix
builtins.typeOf ./.    # => "path"
```

A path is resolved relative to the file it is written in, and copying it into a
derivation copies the file into the store. `"./foo"` is just a string and does
neither. `./foo` in an `imports` list is right; `"./foo"` is not.

**No `~/…` paths in a committed file.** Pure evaluation rejects the whole file
at parse time, even when nothing reads that value, and `tryEval` cannot catch
it. Write `/. + builtins.getEnv "HOME" + "/Code/x"`: pure, `getEnv` returns
`""`, and the path simply does not exist. `~` is fine in a gitignored,
impure-only file such as flake-compatish's `overrides.nix`.

`builtins ? currentSystem` is `false` in pure evaluation and `true` in impure.
That is the test for "am I impure"; `builtins.currentSystem` itself throws
when pure.

## Escaping in strings

In an indented string `''...''`, escape interpolation with `''${`, not `\${`:

```nix
''  literal: ''${NOT_NIX}  ''    # => "literal: ${NOT_NIX}  "
```

That is the form to use for shell variables inside a script written in Nix. In
an ordinary `"..."` string, `\${` is the escape.

## Function arguments

An attrset pattern is strict. Extra keys are an error unless you write `...`:

```nix
({ x }: x) { x = 1; y = 2; }        # error
({ x, ... }: x) { x = 1; y = 2; }   # => 1
```

A default makes the argument optional. An entry point defaults `pkgs` so a
consumer can pass their own — see **Project layout**. Inside a NixOS or
home-manager module, take `{ pkgs, lib, config, ... }:` and never import
nixpkgs yourself.

## Defaults and recursion

`or` supplies a default for a missing attribute:

```nix
{ a = 1; }.b or "dflt"    # => "dflt"
```

`rec` lets an attrset reference its own keys, and so does a `let`:

```nix
rec { a = 1; b = a + 1; }.b                   # => 2
let a = { n = 1; m = a.n + 1; }; in a.m       # => 2
```

Prefer `let`. `rec` makes every key in the set a name in scope, so adding a key
can silently capture a reference meant for an outer binding. In a derivation,
use `finalAttrs` instead — see **Writing a package**.

## The `lib.optional` family

Three different return types, and picking the wrong one is a type error far
from the call site:

```nix
lib.optional  true "x"          # => [ "x" ]     one item -> list
lib.optionals true [ "x" "y" ]  # => [ "x" "y" ] list -> list
lib.optionalString true "s"     # => "s"         string -> string
```

`optional` takes an item and wraps it. `optionals` takes a list and passes it
through. Handing `optional` a list gives you a list of lists.

## Package binaries: `lib.getExe` and `lib.getExe'`

Never build a binary path by hand. `"${pkgs.foo}/bin/foo"` works but bypasses
the `bin` output on multi-output packages; use:

```nix
lib.getExe pkgs.hello                  # => "/nix/store/jxxp01dayz0pv6vp7n39r9042ycsiicx-hello-2.12.3/bin/hello"
lib.getExe' pkgs.imagemagick "convert" # => "/nix/store/1fj0wg21ba24hv612yg4kqwzxbnyappm-imagemagick-7.1.2-29/bin/convert"
```

`getExe pkg` takes the package and reads `meta.mainProgram`. `getExe' pkg name`
takes the binary name too and evaluates to `"${getBin pkg}/bin/${name}"` — the
`bin` output when there is one.

Prefer `getExe` when the package sets `meta.mainProgram`; prefer `getExe'` when
it does not. On a package with no `meta.mainProgram`, `getExe` warns and falls
back to the package name — deprecated, because the guess can pick a binary that
is not the one you mean. `getExe'` asserts its arguments: a derivation, a
string, and a name with no `/` in it.

## Doc comments

`/** ... */` is a doc comment. nixpkgs documents `lib` this way, and nixdoc
extracts it into the manual. Use it for anything with an interface: a function
others call, an exported attribute, a package helper. See `/etc/nixpkgs/lib/`
for hundreds of worked examples — `strings.nix` is a good one.

This does not mean write more comments. The house rule stands: a comment earns
its line, and narration inside a body earns nothing. What this governs is the
*format* when you do document something callable.

Three comment forms, and only one is extracted. Measured with nixdoc 3.2.0:

| form | extracted | notes |
| --- | --- | --- |
| `/** ... */` | yes | you write the sections yourself |
| `/* ... */` | yes, legacy | nixdoc synthesises a bare "Inputs" listing, which is worse than none |
| `# ...` | **no** | invisible to the manual; right for internal notes |

The shape, which renders as nixpkgs renders:

````nix
{
  /**
    One line saying what it does.

    # Inputs

    `sep`
    : Separator placed between elements

    `list`
    : Strings to join

    # Type

    ```
    join :: String -> [String] -> String
    ```

    # Examples
    :::{.example}
    ## `lib.demo.join` usage example

    ```nix
    join ", " [ "foo" "bar" ]
    => "foo, bar"
    ```

    :::
  */
  join = sep: list: builtins.concatStringsSep sep list;
}
````

Notes that cost a test each:

- Headings demote by two. `#` in the source becomes `###` in the manual,
  because the function's own name is `##`. Write `# Inputs`, never `### Inputs`.
- The sections are a convention, not a schema. A description alone extracts
  fine; nixdoc does not require Inputs, Type or Examples.
- **Indentation must be even.** nixdoc strips the common leading whitespace, so
  one under-indented line lowers the baseline and every other line keeps its
  extra spaces — four or more of which markdown renders as a code block. Prose
  turns into a code block with no error anywhere.
- A blank line between the comment and the binding is harmless; the two stay
  associated.
- An attribute that is not a function documents the same way.

Check your work rather than assume it:

```sh
nix run --file /etc/nixpkgs nixdoc -- --file <file>.nix --category demo --description D
```

## Project layout

Template: `demo/` next to this file. Builds, checks pass both ways, and its
README lists what was measured. Copy it instead of inventing a layout.

**`default.nix` is the project. `flake.nix` is a wrapper around it.** A flake is
fine to have. An output reachable only through the flake is not: non-flake
consumers, `nix-shell`, `nix build --file` and other repos importing yours all
lose it.

```nix
# default.nix
let
  compat = import ./nix/compat.nix;   # reads flake.lock via flake-compatish
in
{
  inputs ? compat.inputs,
  system ? builtins.currentSystem,
  pkgs ? import inputs.nixpkgs { inherit system; config = { }; overlays = [ ]; },
}:
let
  greet = pkgs.callPackage ./nix/package.nix { };
in
{
  inherit greet;
  shell = pkgs.callPackage ./nix/shell.nix { inherit greet; };
  checks = pkgs.callPackages ./nix/checks.nix { inherit greet; };
  overlay = import ./nix/overlay.nix;
  nixosModule = ./nix/module.nix;
}
```

```nix
# flake.nix outputs: map default.nix over systems, add nothing
perSystem = lib.genAttrs systems (system: import ./default.nix { inherit inputs system; });
packages = lib.mapAttrs (_: p: { inherit (p) default greet; }) perSystem;
overlays.default = import ./nix/overlay.nix;     # same file default.nix exposes
```

- **One lock.** `flake.lock` pins; `default.nix` reads the same lock. Never a
  second pin (npins, niv, a `fetchTarball` URL) beside it.
- **`pkgs` is an argument with a pinned default.** The consumer's `pkgs` wins,
  so one nixpkgs is instantiated, not two. `import <nixpkgs> { }` as the
  default is impure: the result depends on the caller's `NIX_PATH`.
- **`config = { }; overlays = [ ];`** when importing nixpkgs. Omitted, nixpkgs
  reads `~/.config/nixpkgs/{config,overlays}.nix` and the build varies by user.
- **No `legacyPackages` in `flake.nix`.** It passes no `config` and adds
  `impure-overlays.nix`. Pure under the flake evaluator, but flake-compatish
  evaluates flake outputs impurely: measured, `NIXPKGS_CONFIG` flips its
  `config.allowUnfree`. Let `default.nix` import nixpkgs.
- **`nix/compat.nix` is `import flake-compatish ../.`.** The path form
  evaluates the working copy in place. Its `.compatish.override` changes
  inputs with strict names: a typo is an error, not a silent no-op.
- **`default.nix` only wires.** Each output is one line: a `callPackage` of,
  or a path to, a file in `nix/`. A body longer than that gets its own file.
- **Those files are `callPackage`-able.** Each takes its exact dependencies as
  arguments, never `pkgs`. Project outputs come in by name:
  `callPackage ./nix/shell.nix { inherit greet; }`.
- **An attrset of derivations loads with `callPackages`.** `callPackage` adds
  `override` and `overrideDerivation` to the set, and `nix flake check`
  rejects those as checks.
- **Overlay and module are plain files.** The flake's `overlays.default` and
  `nixosModules.default` and `default.nix`'s `overlay` and `nixosModule` point
  at the same path.
- **A module builds from the consumer's `pkgs`**: package option default
  `pkgs.greet or (pkgs.callPackage ./package.nix { })`. It never imports a
  pinned nixpkgs and never sets `nixpkgs.overlays`.
- **`shell.nix` is `(import ./. { }).shell`**, defined in `nix/shell.nix`.
  `mkShell { inputsFrom = [ pkg ]; }` takes the package's build inputs.
- **Checks live in `nix/checks.nix`**, exposed as `checks` in `default.nix`;
  the flake re-exports them.

## Writing a package

From `/etc/nixpkgs/CONTRIBUTING.md` (Code conventions), `pkgs/README.md`
(Conventions) and `doc/build-helpers/fixed-point-arguments.chapter.md`.
`demo/nix/package.nix` applies all of it.

**`finalAttrs`, not `rec`.** `rec` freezes self-references at definition, so
`overrideAttrs` changes the attribute and not what was built from it:

```nix
# overrideAttrs { version = "2"; } then read .tag:
mkDerivation rec { version = "1"; tag = "v${version}"; }                # => "v1"
mkDerivation (finalAttrs: { version = "1"; tag = "v${finalAttrs.version}"; })  # => "v2"
```

`finalAttrs.finalPackage` is the package itself, for `passthru.tests`.

Arguments and structure:

- Explicit argument list, no `...`, no `args: with args;`.
- No `with lib;` over a file. Write `lib.licenses.mit`.
- `lib.optionals cond [ … ]`, never `if cond then [ … ] else [ ]` or `null`.
- `tag = version;`, never `"${version}"`.
- `passthru` before `meta`; `meta` last.
- New packages: `strictDeps = true;` and `__structuredAttrs = true;`. With
  strictDeps, build-time tools go in `nativeBuildInputs` and linked libraries
  in `buildInputs`, and a wrong choice fails instead of working by accident.
- `"PREFIX=${placeholder "out"}"` in `makeFlags`, not `$out`.
- Version check: `doInstallCheck = true; nativeInstallCheckInputs = [ versionCheckHook ];`.
- No import-from-derivation.

Sources:

- Local source: `lib.fileset.toSource { root = ../.; fileset = lib.fileset.unions [ … ]; }`,
  not `src = ./.;`. `./.` copies everything, `result` links included, and any
  edit to any file rebuilds.
- Remote: `fetchFromGitHub { owner; repo; tag = "v${finalAttrs.version}"; hash; }`,
  or `rev` with a **full** commit hash. A short hash can 404 on GitHub.
  `hash = "sha256-…"`, never `sha256 =`.
- Upstream patch: `fetchpatch2` with a `name` saying why, and
  `?full_index=1` on GitHub URLs.

Names and metadata:

- `pname` lowercase, upstream's name. Attribute name equals `pname`, dashes
  kept. File names kebab-case.
- `version` starts with a digit. Unreleased commit:
  `"<last release>-unstable-YYYY-MM-DD"`, or `"0-unstable-…"`.
- `meta.description`: one sentence, capitalised, no leading article, no
  package name, no trailing period.
- `meta.license` always. `meta.mainProgram` as a literal string when there is
  one main binary — that is what `lib.getExe` reads.
- `meta.sourceProvenance` when repackaging a binary.

Inside nixpkgs, no new `overrideAttrs` on another package: change that
package instead. Outside nixpkgs, overriding is the normal tool.

Format with nixfmt (`pkgs.nixfmt`, `pkgs.nixfmt-tree` as the flake formatter).
nixpkgs CI enforces it.

## Module system, briefly

`imports` resolves before `config` exists. Reading `pkgs` or `config` to decide
what to import makes the module system recurse, and the error it gives names
neither. Pass a `specialArgs` value instead.

## Python package sets: override the interpreter, not the set

`python312Packages` is `python312.pkgs` (`all-packages.nix`), and
`python3Packages` is `python314Packages`. One scope per interpreter version.

Overriding the set misses the interpreter-bound users:

```nix
pkgs.python312Packages.override { overrides = _: p: { ...; }; }
# pkgs.python312Packages.anyio => qfpl1c9355j30in9yinpf65m5d6nr909-python3.12-anyio-4.14.2.drv
# pkgs.python312.pkgs.anyio     => h595cdhgvy8s9ajn3b4xrpxrwy8isylm-python3.12-anyio-4.14.2.drv
```

Two different derivations. nixpkgs-internals such as `odoo18` resolve through
the interpreter-bound set, so they never see the fix.

Override the interpreter with `packageOverrides` instead. The top-level set
follows through the fixed point, so no set entry is needed:

```nix
final: prev: {
  python312 = prev.python312.override {
    packageOverrides = _: pprev: {
      anyio = pprev.anyio.overridePythonAttrs (_: { doCheck = false; });
    };
  };
}
# pkgs.python312Packages.anyio => qfpl1c9355j30in9yinpf65m5d6nr909-python3.12-anyio-4.14.2.drv
# pkgs.python312.pkgs.anyio     => qfpl1c9355j30in9yinpf65m5d6nr909-python3.12-anyio-4.14.2.drv
```

Same hash both ways. After any Python overlay, evaluate both spellings and
require agreement — a second, divergent derivation in one tree means the
override hit one scope and missed the other.

Use `overridePythonAttrs`, not `overrideAttrs`, on a Python package.
`overrideAttrs` on the `toPythonModule` wrapper returns the same derivation
hash with the change silently absent.
