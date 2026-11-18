# vivarium tests of this configuration's own modules.
#
#   nix build --file . tests.boot-guard              # the verdict
#   vivarium run tests.boot-guard --out DIR --break-on-failure --until-pause
{ mkTest }:
{
  boot-guard = import ./boot-guard { inherit mkTest; };
}
