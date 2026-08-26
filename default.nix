let
  inputs =
    (
      let
        lockAttrs = builtins.fromJSON (builtins.readFile ./flake.lock);

        # Look the node up through the root's own input map rather than by the
        # name `flake-compatish`. A lock file names nodes uniquely, so as soon
        # as another input depends on flake-compatish too, the two get
        # `flake-compatish` and `flake-compatish_2` and which one is ours is
        # not decided by the name. Reading the name directly silently pinned
        # this to whichever revision the *other* input wanted.
        nodeName = lockAttrs.nodes.${lockAttrs.root}.inputs.flake-compatish;
        flake-compatish = import (fetchTree lockAttrs.nodes.${nodeName}.locked);
      in
      flake-compatish {
        source = ./.;

        # Point an input at a checkout next door in ./overrides.nix, NOT here.
        # flake-compatish reads that file next to `source` on its own, it is
        # gitignored, and a value in it beats anything passed to this argument
        # -- so every machine states its own development paths and none of them
        # reach the repository.
        #
        # That file is also the only place where a path may be absent: an
        # override naming a path that is not there falls back to the lockfile
        # rather than failing, which is what makes one gitignored file per
        # machine work. It is read in impure evaluation only, so a pure
        # `nix build` of this repo ignores it.
        #
        # `self` stays here because it is not machine-local. Without it
        # flake-compatish copies this whole tree into the store on every
        # evaluation to answer `self`; naming the path uses the working copy
        # directly. A fresh clone with no ./overrides.nix still gets that.
        overrides = {
          self = ./.;

          # These two were here until the move to ./overrides.nix, and they
          # only ever resolved on hetztop. Left as a record of what that
          # machine was building against, so whoever is next on it can decide
          # rather than guess.
          #
          # To restore them, write them to ./overrides.nix on hetztop -- that
          # file is gitignored, so they stay on the machine they describe.
          # Uncommenting them here puts a path that exists on one machine into
          # a repository shared by three, which is what the move undid.
          #
          #   acpcli = /home/lillecarl/Code/acpcli;
          #   nanopynix = /home/lillecarl/Code/nanopynix;
          #
          # Check before restoring nanopynix: it was pinned to a local checkout
          # because the locked input had no pynixd/nix/nixos for hosts/hetztop
          # to import. The input has since moved to a revision that has it, so
          # the override may now be doing nothing but hiding upstream.
        };
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
  #
  # `./pkgs` takes `inputs` before `final: prev:`. Only one package in it needs
  # them -- agenix, which is built from a `flake = false` source tree -- but the
  # alternative was building that one somewhere else, and then `pkgs.agenix`
  # would not exist. It has to be in the overlay for `nix run --file . pkgs.agenix`
  # to resolve, and nixpkgs has no `agenix` of its own to fall back on.
  pkgsFor =
    system:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [ (import ./pkgs inputs) ];
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
  dynhetz = dynhetzSystem { };
  dynhetzx = dynhetzSystem { system = "x86_64-linux"; };
  dynhetzSystem =
    {
      system ? currentSystem,
    }:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = specialArgsFor system;
      modules = [
        ./hosts/dynhetz
        (pkgsModule system)
      ];
    };
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
