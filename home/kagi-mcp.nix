# kagi-mcp for OpenCode only. Claude Code has its own search engine,
# so this MCP is not configured there.
#
# The server reads KAGI_AUTH_TOKEN from the environment. The wrapper loads it
# from the user secret, or from ~/.config/kagi/token where no system decrypts
# secrets (cros), so the token never enters opencode.json or the store.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  kagiWrapped = pkgs.writeShellApplication {
    name = "kagi-mcp-wrapped";
    runtimeInputs = [
      pkgs.kagi-mcp
      pkgs.coreutils
    ];
    text = ''
      if [ -z "''${KAGI_AUTH_TOKEN:-}" ]; then
        for f in ${config.croshome.userSecrets.kagi-token.path} "$HOME/.config/kagi/token"; do
          if [ -r "$f" ]; then
            KAGI_AUTH_TOKEN="$(cat "$f")"
            export KAGI_AUTH_TOKEN
            break
          fi
        done
      fi
      exec kagi-mcp "$@"
    '';
  };
in
{
  croshome.userSecrets.kagi-token = { };

  home.packages = [
    pkgs.kagi-mcp
    kagiWrapped
  ];

  # Merges `mcp.kagi` into ~/.config/opencode/opencode.json through
  # ../modules/home/merged-file.nix, alongside ./opencode.nix's `instructions`.
  home.mergedFile.".config/opencode/opencode.json" = {
    format = "json";
    settings.mcp.kagi = {
      type = "local";
      command = [ (lib.getExe kagiWrapped) ];
      enabled = true;
    };
  };
}
