# What shitbox must keep across a refactor or a nixpkgs bump: everything that
# decides whether the disk unlocks and mounts, and what makes up the niri
# session. Evaluate it against two configurations and diff the JSON;
# ./check-contract does that against the legacy ~/Code/nixos flake or this
# repository.
#
# Store paths are left in: the script normalises their hashes, so a
# difference that survives is a version or a content change worth reading.
{
  lib,
  # A NixOS configuration's `config`.
  nixos,
  # The home-manager `config` for lillecarl: standalone in the legacy repo,
  # nixos.home-manager.users.lillecarl here.
  home,
}:
let
  b = nixos.boot;
  # Options nixpkgs has removed throw when read; this reads them as `d`.
  try =
    v: d:
    let
      r = builtins.tryEval v;
    in
    if r.success then r.value else d;
  sortU = l: lib.sort lib.lessThan (lib.unique l);
  enabledNames = s: sortU (lib.attrNames (lib.filterAttrs (_: v: v == true) s));
  graphicalTargets = [
    "graphical-session.target"
    "niri-session.target"
    "niri.service"
  ];
in
{
  disk = {
    fileSystems = lib.mapAttrs (_: f: {
      inherit (f) device fsType neededForBoot;
      options = sortU f.options;
    }) nixos.fileSystems;

    swapDevices = map (s: {
      inherit (s) device priority discardPolicy;
      randomEncryption = s.randomEncryption.enable;
    }) nixos.swapDevices;

    luks = lib.mapAttrs (_: d: {
      inherit (d)
        device
        allowDiscards
        bypassWorkqueues
        keyFile
        ;
      # Scripted stage 1 only; gone with it in nixpkgs 26.05.
      preLVM = try d.preLVM null;
    }) b.initrd.luks.devices;

    swraid = {
      inherit (b.swraid) enable mdadmConf;
    };

    lvm = {
      enable = nixos.services.lvm.enable;
      thin = nixos.services.lvm.boot.thin.enable;
      initrd = b.initrd.services.lvm.enable;
    };

    initrd = {
      # Always true from nixpkgs 26.05 on, where the option is removed.
      systemd = try b.initrd.systemd.enable true;
      systemdNetwork = {
        enable = b.initrd.systemd.network.enable;
        networks = lib.mapAttrs (_: n: {
          inherit (n) matchConfig networkConfig;
          dhcpV4Config = n.dhcpV4Config or { };
        }) b.initrd.systemd.network.networks;
      };
      rootShell = b.initrd.systemd.users.root.shell or null;
      availableKernelModules = sortU b.initrd.availableKernelModules;
      kernelModules = sortU b.initrd.kernelModules;
      supportedFilesystems = enabledNames b.initrd.supportedFilesystems;
      # Scripted stage 1 only; reading it is an error from nixpkgs 26.05 on.
      extraUtilsCommands = try b.initrd.extraUtilsCommands "";
      network = {
        inherit (b.initrd.network) enable flushBeforeStage2;
        udhcpc = {
          enable = try b.initrd.network.udhcpc.enable false;
          extraArgs = try b.initrd.network.udhcpc.extraArgs [ ];
        };
        ssh = {
          inherit (b.initrd.network.ssh)
            enable
            port
            hostKeys
            authorizedKeys
            ;
        };
      };
    };

    loader = {
      grub = {
        inherit (b.loader.grub)
          enable
          device
          devices
          efiSupport
          enableCryptodisk
          copyKernels
          efiInstallAsRemovable
          ;
      };
      efi = {
        inherit (b.loader.efi) canTouchEfiVariables efiSysMountPoint;
      };
      systemd-boot = b.loader.systemd-boot.enable;
    };

    # The VFIO setup rides on these as much as the disk does.
    kernel = {
      version = b.kernelPackages.kernel.version;
      params = sortU b.kernelParams;
      modules = sortU b.kernelModules;
      blacklisted = sortU b.blacklistedKernelModules;
      inherit (b) extraModprobeConfig;
      redistributableFirmware = nixos.hardware.enableRedistributableFirmware;
    };
  };

  wm = {
    niri = {
      enable = nixos.programs.niri.enable;
      version = nixos.programs.niri.package.version;
    };
    configKdl = builtins.readFile "${home.home-files}/.config/niri/config.kdl";
    # User services that start with the graphical session.
    userServices = sortU (
      lib.attrNames (
        lib.filterAttrs (
          _: s: lib.any (t: lib.elem t graphicalTargets) (s.Install.WantedBy or [ ])
        ) home.systemd.user.services
      )
    );
    # Set from NixOS or home-manager; either one counts.
    portals =
      let
        side = x: {
          enable = x.xdg.portal.enable or false;
          packages = sortU (map (p: p.pname or p.name) (x.xdg.portal.extraPackages or [ ]));
        };
      in
      {
        nixos = side nixos;
        home = side home;
      };
  };
}
