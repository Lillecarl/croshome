{ pkgs, lib, ... }:
{
  programs.helix = {
    enable = true;
    defaultEditor = true;
    extraPackages = [
      pkgs.bash-language-server
      pkgs.fish-lsp
      pkgs.marksman
      pkgs.ruff
      pkgs.tombi
      pkgs.vscode-langservers-extracted
      pkgs.yaml-language-server
      pkgs.pyright
    ];
    languages = {
      language-server.pyright = {
        command = "${lib.getExe' pkgs.pyright "pyright-langserver"}";
        args = [ "--stdio" ];
        config.pyright = {
          typeCheckingMode = "strict";
          disableOrganizeImports = false;
        };
      };
      language-server.ruff = {
        command = "${lib.getExe pkgs.ruff}";
        args = [
          "server"
          "--preview"
        ];
      };
      language = [
        {
          name = "python";
          language-servers = [
            "pyright"
            "ruff"
          ];
          auto-format = true;
        }
      ];
    };
  };
}
