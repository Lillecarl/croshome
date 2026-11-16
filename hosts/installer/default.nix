# Throwaway installer ISO: boot it once, then point nixos-anywhere at it.
#
#   nix build --file . installer
#   nixos-anywhere --target-host root@<ip> ...   # password below
#
# The password is plaintext on purpose. The ISO lives only until the target
# is installed, and the installed system does not inherit it.
{ lib, modulesPath, ... }:
{
  # latest-kernel.nix drops ZFS: zfs-kernel usually lags linuxPackages_latest
  # and is marked broken against it. A ZFS target needs the default kernel.
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    "${modulesPath}/installer/cd-dvd/latest-kernel.nix"
  ];

  # iso-image.nix sets 10 without a priority. Not 0: syslinux reads
  # TIMEOUT 0 as "wait forever", so a BIOS boot would hang at the menu.
  boot.loader.timeout = lib.mkForce 1;

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };

  # installation-device.nix sets an empty initialHashedPassword. Clearing it
  # avoids the "multiple password options" warning.
  users.users.root = {
    initialHashedPassword = lib.mkForce null;
    password = "plsinstallmenow";
  };

  system.stateVersion = lib.trivial.release;
}
