/**
  The numpad remote control: the daemon in ./core, the actions in plugins.

  This is the daemon with no plugins. `withPlugins` picks some:

  ```nix
  remapper.withPlugins (ps: [ ps.libvirt ps.ddc ])
  ```

  A plugin is a Python distribution with an entry point in the group
  `remapper.plugins` and a `passthru.runtimeTools` list, which goes on the
  daemon's PATH. The daemon finds only the plugins in its environment.
*/
{
  lib,
  python3,
  makeWrapper,
  runCommand,
  avizo,
  ddcutil,
  libvirt,
  pipewire,
  wireplumber,
}:
let
  ps = python3.pkgs;
  core = ps.callPackage ./core { };
  # The arguments are the top-level packages: the Python set has its own
  # `libvirt`, the bindings.
  plugins = {
    audio = ps.callPackage ./plugins/audio {
      remapper = core;
      inherit avizo pipewire wireplumber;
    };
    ddc = ps.callPackage ./plugins/ddc {
      remapper = core;
      inherit ddcutil;
    };
    libvirt = ps.callPackage ./plugins/libvirt {
      remapper = core;
      inherit libvirt;
    };
  };

  withPlugins =
    choose:
    let
      chosen = choose plugins;
      env = python3.withPackages (_: [ core ] ++ chosen);
    in
    runCommand "remapper-${core.version}"
      {
        nativeBuildInputs = [ makeWrapper ];
        passthru = {
          inherit core plugins withPlugins;
          plugged = chosen;
        };
        meta = core.meta;
      }
      ''
        makeWrapper ${env}/bin/remapper $out/bin/remapper \
          --prefix PATH : ${lib.makeBinPath (lib.concatMap (p: p.runtimeTools) chosen)}
        # Udev rules a plugin ships, for services.udev.packages.
        for plugin in ${lib.escapeShellArgs chosen}; do
          if [ -d "$plugin/lib/udev/rules.d" ]; then
            mkdir -p $out/lib/udev/rules.d
            ln -s "$plugin"/lib/udev/rules.d/* $out/lib/udev/rules.d/
          fi
        done
      '';
in
withPlugins (_: [ ])
