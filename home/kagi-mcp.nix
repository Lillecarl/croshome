# kagi-mcp for OpenCode only. Claude Code has its own search engine,
# so this MCP is not configured there. The package is installed on every
# host that imports ../../home (macbook and hetztop, not cros), and the
# OpenCode config is patched to run it.
#
# Secrets: the server reads KAGI_AUTH_TOKEN from the environment. The
# wrapper below loads it from a file if present, so the token never enters
# the nix store or the repository. Four locations are checked in order:
#
#   /run/agenix/kagi-token                       -- system agenix (macbook, hetztop via ../secrets)
#   $XDG_RUNTIME_DIR/agenix/kagi-token           -- home agenix on Linux
#   $(getconf DARWIN_USER_TEMP_DIR)/agenix/kagi-token -- home agenix on Darwin
#   $HOME/.config/kagi/token                     -- plain file for quick local use
#
# Home agenix is the preferred path for this token, because it works on
# every host including cros (which has no system agenix). See ./agenix.nix
# for the module and ../secrets/secrets.nix for the recipient list.
# To create the secret (once):
#
#   cd secrets
#   nix run --file .. pkgs.agenix -- -e kagi-token.age -i identity.age
#   # paste the token (no newline), save and exit
#   # then rekey to ensure recipients are current:
#   nix run --file .. pkgs.agenix -- -r -i identity.age
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  # Wrapper that loads KAGI_AUTH_TOKEN from a file if the environment does
  # not already have it. This keeps the token out of opencode.json and out
  # of the nix store; opencode's mcp.environment therefore stays empty.
  # The order covers system agenix, home agenix (Linux + Darwin), then the
  # plain fallback. Home agenix paths are the defaults from age-home.nix:
  #   Linux  $XDG_RUNTIME_DIR/agenix/<name>
  #   Darwin $(getconf DARWIN_USER_TEMP_DIR)/agenix/<name>
  kagiWrapped = pkgs.writeShellApplication {
    name = "kagi-mcp-wrapped";
    runtimeInputs = [
      pkgs.kagi-mcp
      pkgs.coreutils
    ];
    text = ''
      if [ -z "''${KAGI_AUTH_TOKEN:-}" ]; then
        # System agenix (NixOS / nix-darwin)
        if [ -f /run/agenix/kagi-token ]; then
          KAGI_AUTH_TOKEN="$(cat /run/agenix/kagi-token)"
          export KAGI_AUTH_TOKEN
        # Home agenix on Linux
        elif [ -n "''${XDG_RUNTIME_DIR:-}" ] && [ -f "''${XDG_RUNTIME_DIR}/agenix/kagi-token" ]; then
          KAGI_AUTH_TOKEN="$(cat "''${XDG_RUNTIME_DIR}/agenix/kagi-token")"
          export KAGI_AUTH_TOKEN
        # Home agenix on Darwin
        elif darwinDir="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; [ -n "''${darwinDir:-}" ] && [ -f "''${darwinDir}agenix/kagi-token" ]; then
          KAGI_AUTH_TOKEN="$(cat "''${darwinDir}agenix/kagi-token")"
          export KAGI_AUTH_TOKEN
        elif [ -f "''${HOME}/.config/kagi/token" ]; then
          KAGI_AUTH_TOKEN="$(cat "''${HOME}/.config/kagi/token")"
          export KAGI_AUTH_TOKEN
        fi
      fi
      exec kagi-mcp "$@"
    '';
  };

  # Merges `mcp.kagi` into ~/.config/opencode/opencode.json through
  # ./merged-file.nix, alongside ./opencode.nix's `instructions`: both name
  # the same file and their settings merge. The rest of opencode.json stays
  # hand-managed.
in
{
  # Home agenix secret. Decrypted to $XDG_RUNTIME_DIR/agenix/kagi-token
  # (Linux) or $(getconf DARWIN_USER_TEMP_DIR)/agenix/kagi-token (Darwin).
  # The file at ../secrets/kagi-token.age must list lillecarl-age plus the
  # SSH keys that home agenix uses (see ../secrets/secrets.nix).
  age.secrets.kagi-token.file = ../secrets/kagi-token.age;

  home.packages = [
    pkgs.kagi-mcp
    kagiWrapped
  ];

  home.mergedFile.".config/opencode/opencode.json" = {
    format = "json";
    settings.mcp.kagi = {
      type = "local";
      command = [ (lib.getExe kagiWrapped) ];
      enabled = true;
    };
  };
}
