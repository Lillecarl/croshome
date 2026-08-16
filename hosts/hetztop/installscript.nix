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
            PATH=${lib.makeBinPath [ pkgs.nixos-anywhere ]}:$PATH
            set -x
            nixos-anywhere \
              --flake .#hetztop \
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
              --flake .#${config.lib.hetzkube.configName} \
              --attr nixosConfigurations.hetztop \
              --target-host root@${IP} \
              --build-host root@${IP}
          '';
    };
}
