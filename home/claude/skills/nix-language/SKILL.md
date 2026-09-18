---
name: nix-language
description: The Nix language itself — syntax and semantics that models reliably get wrong. Use before writing or editing any .nix file, and when a Nix expression fails to parse or evaluates to something unexpected. Covers attribute key quoting, the shallow // merge, with scoping, list syntax, paths versus strings, string escaping, function arguments and the lib.optional family. For running nix commands, use the nix skill.
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

A default makes the argument optional: `{ pkgs ? import <nixpkgs> { } }:`. That
is the entry-point convention — it lets a consumer supply their own `pkgs`
instead of pinning one for them. Inside a NixOS or home-manager module, take
`{ pkgs, lib, config, ... }:` and never import nixpkgs yourself.

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
can silently capture a reference meant for an outer binding.

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

## Module system, briefly

`imports` resolves before `config` exists. Reading `pkgs` or `config` to decide
what to import makes the module system recurse, and the error it gives names
neither. Pass a `specialArgs` value instead.
