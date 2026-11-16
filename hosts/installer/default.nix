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

  # Size: nixos-anywhere copies the closure in over ssh, so the target needs
  # no nixpkgs source, manuals or git. git alone drags in python3.
  system.installer.channel.enable = false;
  documentation = {
    enable = lib.mkForce false;
    doc.enable = lib.mkForce false;
    man.enable = lib.mkForce false;
    nixos.enable = lib.mkForce false;
  };
  programs.git.enable = lib.mkForce false;
  # The flake registry pins nixpkgs to a 200M source copy.
  nixpkgs.flake.setFlakeRegistry = false;
  nixpkgs.flake.setNixPath = false;
  # cifs-utils pulls in python3. A network share is no install target.
  boot.supportedFilesystems.cifs = lib.mkForce false;
  # nixos-rebuild-ng is python3 too. nixos-anywhere calls only nixos-install
  # and nixos-generate-config, which stay.
  system.tools.nixos-rebuild.enable = false;

  # dhcpcd on every interface, in place of NetworkManager and ModemManager.
  # Wi-Fi then needs wpa_supplicant by hand; wired is the target here.
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = lib.mkForce true;

  system.stateVersion = lib.trivial.release;
}
