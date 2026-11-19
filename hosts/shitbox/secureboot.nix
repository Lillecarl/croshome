# Secure Boot through lanzaboote: systemd-boot and signed UKIs on the ESP,
# keys under /var/lib/sbctl. The first switch generates the keys and stages
# them on the ESP; systemd-boot enrolls them on the next boot that finds the
# firmware in Setup Mode.
#
# The Microsoft keys go in too: the Arc's and the RTX's option ROMs are signed
# by Microsoft's UEFI CA, and without them neither card shows the firmware.
{
  inputs,
  pkgs,
  ...
}:
{
  # By path, not `import inputs.lanzaboote { inherit pkgs; }`, because
  # imports must not read pkgs.
  imports = [ (inputs.lanzaboote.outPath + "/nix/modules/lanzaboote.nix") ];

  boot.lanzaboote = {
    enable = true;
    package = (import inputs.lanzaboote.outPath { inherit pkgs; }).packages.lzbt;
    pkiBundle = "/var/lib/sbctl";
    # A UKI is about 60M; the 10G ESP holds this many with room to spare.
    configurationLimit = 20;
    autoGenerateKeys.enable = true;
    autoEnrollKeys.enable = true;
  };

  environment.systemPackages = [ pkgs.sbctl ];
}
