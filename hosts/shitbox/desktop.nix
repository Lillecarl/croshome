# What the niri session needs from the system. niri itself comes from
# niri-flake (pinned in ../../flake.nix to what ~/Code/nixos ran), whose
# module also brings the gnome portal, polkit agent, gnome-keyring and the
# swaylock PAM service.
{ inputs, pkgs, ... }:
{
  imports = [ inputs.niri.nixosModules.niri ];

  programs.niri = {
    enable = true;
    # niri at this pin wants libdisplay-info 0.2, which nixpkgs has since
    # dropped. Build 0.2 from the 25.11 package against today's nixpkgs
    # rather than move niri; drop the override when niri is bumped.
    # `.override` cannot get around it: niri-flake asserts on the removed
    # alias before an override applies, so the attribute has to exist in the
    # package set niri-flake's overlay is applied to.
    package =
      let
        withOldDisplayInfo = pkgs.extend (
          final: _: {
            libdisplay-info_0_2 = final.callPackage "${inputs.nixpkgs-stable}/pkgs/by-name/li/libdisplay-info_0_2/package.nix" { };
          }
        );
      in
      (withOldDisplayInfo.extend inputs.niri.overlays.niri).niri-unstable;
  };

  # The swaylock entry from niri-flake, plus keyring unlock on login.
  security.pam.services = {
    login.enableGnomeKeyring = true;
    swaylock.enableGnomeKeyring = true;
  };

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
  services.blueman.enable = true;

  services.udisks2.enable = true; # udiskie
  hardware.uinput.enable = true;
  services.fwupd.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
  };
}
