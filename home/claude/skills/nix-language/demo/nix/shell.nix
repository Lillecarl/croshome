{
  mkShell,
  nixfmt,
  greet,
}:

mkShell {
  inputsFrom = [ greet ];
  packages = [ nixfmt ];
}
