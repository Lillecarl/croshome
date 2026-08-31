{
  config,
  pkgs,
  lib,
  ...
}:
{
  config =
    let
      IP = builtins.getEnv "HIP";
      system = "x86_64-linux";
    in
    {
      lib.anywhereScript =
        pkgs.writeScriptBin "imageinstall" # bash
          ''
            #! ${pkgs.runtimeShell}
            PATH=${lib.makeBinPath [
              pkgs.nixos-anywhere
              pkgs.openssh
              pkgs.coreutils
              pkgs.gawk
            ]}:$PATH
            set -euo pipefail
            set -x

            tmpDir=$(mktemp -d)
            trap 'rm -rf "$tmpDir"' EXIT

            # nixos-anywhere's own --flake path runs
            # `nix build --eval-store auto --store ssh-ng://...` internally:
            # evaluate locally, stream the build through an ssh-ng
            # connection to a *second*, remote store. That nesting lost a
            # plain (non-derivation) store path partway through copying the
            # closure across -- a Cargo.lock file nixpkgs' Rust build
            # support (`importCargoLock`) copies straight into the store
            # during evaluation, for a home-manager package (jj-hunk) that
            # has nothing to do with dynhetz itself. Reproduced twice,
            # identically, so it's the store nesting, not a one-off GC
            # race.
            #
            # The fix: never hand nixos-anywhere a --flake. Build both
            # pieces ourselves with a single, ordinary distributed build
            # (ssh:// builder, one local store, ordinary temp GC roots) and
            # hand it the finished store paths with -s/--store-paths
            # instead. `--file .` (../../default.nix's non-flake
            # entrypoint) rather than the flake: it evaluates impurely by
            # default, so none of this needs `--option pure-eval false`
            # either. `dynhetzx`, not `dynhetz`: this file's own `dynhetz`
            # attribute is `system = currentSystem` (aarch64-darwin, native
            # to whoever runs this script) -- `dynhetzx` is the real
            # x86_64-linux target.
            #
            # Built on the target dedi itself (its own Ryzen 7700, already
            # reachable as the nixos-anywhere-kexec'd installer), not
            # nix-community: this is personal configuration, and
            # nix-community's builders are not for that.
            #
            # The installer's ssh host key is ephemeral (regenerated each
            # kexec boot, unrelated to the final system's), so it's fetched
            # fresh here and passed straight to --builders rather than
            # needing it pre-populated into root's own known_hosts --
            # base64(algorithm + key, no hostname), per nix's own
            # machines(5) format.
            # grep'd down to the one real key line first: ssh-keyscan has
            # occasionally leaked its "# host:port banner" line onto stdout
            # alongside the real one (normally stderr-only), which silently
            # corrupts the base64 below into two lines instead of one.
            hostKey=$(ssh-keyscan -t ed25519 ${IP} 2>/dev/null | grep "^${IP} " | tail -1 | awk '{print $2, $3}')
            hostKeyB64=$(printf '%s' "$hostKey" | base64 | tr -d '\n')
            builder="ssh://root@${IP} ${system} - 16 1 - - $hostKeyB64"

            nixBuild() {
              nix build --file . --print-out-paths --no-link \
                --max-jobs 0 \
                --builders "$builder" \
                -o "$tmpDir/$1" \
                "$2"
            }

            diskoScript=$(nixBuild disko dynhetzx.config.system.build.diskoScript)
            nixosSystem=$(nixBuild toplevel dynhetzx.config.system.build.toplevel)

            # ../initrd-ssh.nix bakes its host key into the closure directly
            # (./initrd_ssh_host_ed25519_key, checked into the repo), so
            # there's nothing left to stage onto the installer here -- the
            # key nixos-anywhere builds and installs already has it.
            #
            # ../disko.nix's cryptroot has no keyFile: disko's own install
            # step prompts for the LUKS passphrase interactively, right here
            # in this terminal, the moment it formats the array.
            #
            # "$@": lets a caller pass e.g. `--phases kexec` to stop short
            # of disko -- useful for re-testing the build/kexec path
            # without repartitioning a dedi that's already formatted.
            nixos-anywhere \
              -s "$diskoScript" "$nixosSystem" \
              --target-host root@${IP} \
              --kexec https://github.com/nix-community/nixos-images/releases/download/nixos-25.05/nixos-kexec-installer-noninteractive-${system}.tar.gz \
              "$@"
            ssh-keygen -R ${IP}
          '';
      lib.rebuildScript =
        pkgs.writeScriptBin "imagedeploy" # bash
          ''
            #! ${pkgs.runtimeShell}
            PATH=${lib.makeBinPath [ pkgs.nixos-rebuild-ng ]}:$PATH
            set -x
            nixos-rebuild switch \
              --use-substitutes \
              --flake .#dynhetz \
              --target-host root@${IP} \
              --build-host root@${IP}
          '';
    };
}
