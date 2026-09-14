# Accounts for other people, one directory per user under ./dynusers. A
# directory becomes a normal, unprivileged user whose authorized keys are the
# .pub files in it -- adding a directory and its keys is the whole change.
#
# Passwords stay locked until set by hand; with users.mutableUsers a rebuild
# does not reset what a user then chose.
{
  lib,
  pkgs,
  ...
}:
let
  dynusers = ./dynusers;

  userNames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir dynusers)
  );

  keyFiles = name:
    map (file: dynusers + "/${name}/${file}") (
      lib.filter (lib.hasSuffix ".pub") (
        builtins.attrNames (builtins.readDir (dynusers + "/${name}"))
      )
    );
in
{
  users.mutableUsers = true;

  users.users = lib.listToAttrs (
    map
      (name: {
        inherit name;
        value = {
          isNormalUser = true;
          shell = pkgs.fish;
          openssh.authorizedKeys.keyFiles = keyFiles name;
        };
      })
      userNames
  );
}
