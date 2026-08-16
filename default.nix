let
  # A checkout next door wins over the locked input. These paths only exist on
  # the Linux workstation; on the MacBook there is nothing at them, and an
  # override pointing at a path that is not there fails the whole evaluation.
  # So state the candidates and keep the ones that exist.
  localCheckouts = {
    acpcli = /home/lillecarl/Code/acpcli;
    nanopynix = /home/lillecarl/Code/nanopynix;
  };

  presentCheckouts = builtins.listToAttrs (
    builtins.filter (entry: builtins.pathExists entry.value) (
      builtins.attrValues (
        builtins.mapAttrs (name: value: {
          inherit name value;
        }) localCheckouts
      )
    )
  );

  inputs =
    (
      let
        lockAttrs = builtins.fromJSON (builtins.readFile ./flake.lock);
        flake-compatish = import (fetchTree lockAttrs.nodes.flake-compatish.locked);
      in
      flake-compatish {
        source = ./.;
        overrides = {
          self = ./.;
        }
        // presentCheckouts;
      }
    ).inputs;
in
rec {
  inherit inputs;

  lib = inputs.nixpkgs.lib;

  # One package set per system, defined once. Every host below hands its own
  # set to `nixpkgs.pkgs`, so a configuration and the `pkgs` attribute of this
  # file are the same instantiation rather than two that happen to agree.
  #
  # This is also what gives the standalone home-manager configuration the
  # overlay: passing `pkgs` to `homeManagerConfiguration` makes it ignore the
  # `nixpkgs.*` options, so an overlay stated there would silently do nothing.
  pkgsFor =
    system:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [ (import ./pkgs) ];
    };

  # `imports` is resolved before `config` exists. A module list chosen from
  # `pkgs` therefore makes the module system recurse: `pkgs` is itself an
  # option, and reading it decides which modules define it.
  #
  # `lib.systems.elaborate` answers isDarwin/isLinux from the system string
  # alone. That makes it safe to pass as a specialArg, and a specialArg is
  # available in `imports` -- which is what lets ./home pick ./home/darwin or
  # ./home/linux without a fixed point.
  platformFor = system: lib.systems.elaborate system;

  # The same names on all three hosts, so a shared home module reads one set of
  # arguments no matter which evaluation pulled it in.
  #
  # `homeArgs` is the subset home-manager gets. It deliberately leaves out
  # `pkgs`: an extraSpecialArg overrides `_module.args.pkgs`, which is the very
  # thing `useGlobalPkgs` and the standalone `pkgs` argument are there to set.
  homeArgsFor = system: {
    inherit inputs system;
    platform = platformFor system;
    self = ./.;
    selfStr = toString ./.;
  };

  specialArgsFor = system: homeArgsFor system // { homeArgs = homeArgsFor system; };

  # Hands a configuration the package set from `pkgsFor`, so a host and the
  # `pkgs` attribute of this file are one instantiation rather than two that
  # happen to agree.
  #
  # A module and not a specialArg: `specialArgs.pkgs` shadows the option
  # instead of setting it, and NixOS then warns that `nixpkgs.config` and
  # `nixpkgs.overlays` are being ignored -- which is true, and is why they are
  # stated in `pkgsFor` rather than in a module.
  pkgsModule = system: { nixpkgs.pkgs = pkgsFor system; };

  # `builtins.currentSystem` is absent under pure evaluation, and `or` is what
  # turns that from a confusing failure deep in nixpkgs into this message.
  currentSystem =
    builtins.currentSystem
      or (throw "no system: pass `system` explicitly, `builtins.currentSystem` is unavailable here");

  pkgs = pkgsFor currentSystem;

  macbook = macbookSystem { };
  macbookSystem =
    {
      system ? currentSystem,
    }:
    inputs.nix-darwin.lib.darwinSystem {
      specialArgs = specialArgsFor system;
      modules = [
        ./hosts/macbook
        (pkgsModule system)
      ];
    };

  hetztop = hetztopSystem { };
  hetztopx = hetztopSystem { system = "x86_64-linux"; };
  hetztopSystem =
    {
      system ? currentSystem,
    }:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = specialArgsFor system;
      modules = [
        ./hosts/hetztop
        (pkgsModule system)
      ];
    };

  # ChromeOS runs home-manager on its own: there is no NixOS underneath to hang
  # it off, so this is the standalone entry point rather than a system.
  cros = crosHome { };
  crosHome =
    {
      system ? currentSystem,
    }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsFor system;
      extraSpecialArgs = homeArgsFor system;
      modules = [ ./hosts/cros/home.nix ];
    };

  hetztop-options = lib.pipe (pkgs.lib.optionAttrSetToDocList hetztop.options) [
    (lib.filter (v: v.visible && !v.internal))
    (lib.foldl' (
      acc: opt:
      lib.recursiveUpdate acc (
        lib.setAttrByPath opt.loc {
          description = opt.description or "";
          example = opt.example.text or opt.example or "";
          type = opt.type or "";
        }
      )
    ) { })
  ];

  oc = hetztop.config;
  hc = oc.home-manager.users.lillecarl;
}
