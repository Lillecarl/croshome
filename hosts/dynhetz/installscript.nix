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
            ]}:$PATH
            set -euo pipefail

            # ../initrd-ssh.nix bakes its host key into the closure directly
            # (./initrd_ssh_host_ed25519_key, checked into the repo), so
            # there's nothing left to stage onto the installer here -- the
            # key nixos-anywhere builds and installs already has it.
            #
            # ../disko.nix's cryptroot has no keyFile: disko's own install
            # step prompts for the LUKS passphrase interactively, right here
            # in this terminal, the moment it formats the array.
            set -x
            nixos-anywhere \
              --flake .#dynhetz \
              --target-host root@${IP} \
              --build-on remote \
              --kexec https://github.com/nix-community/nixos-images/releases/download/nixos-25.05/nixos-kexec-installer-noninteractive-${system}.tar.gz
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
