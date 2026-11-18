# ./.sops.yaml as an attrset; `secrets sync` writes it as JSON, which sops
# reads as YAML.
{ lib }:
let
  keys = import ./keys.nix;
  admins = lib.attrValues keys.admins;
  hostFiles = lib.mapAttrs' (host: _: lib.nameValuePair "hosts/${host}.yaml" [ host ]) keys.hosts;
  files = hostFiles // keys.files;
  rule = file: hosts: {
    path_regex = "(^|/)${lib.escapeRegex file}$";
    key_groups = [ { age = admins ++ map (h: keys.hosts.${h}) hosts; } ];
  };
in
{
  creation_rules = lib.mapAttrsToList rule files;
}
