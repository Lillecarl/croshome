# kagi-mcp for OpenCode only. Claude Code has its own search engine,
# so this MCP is not configured there. The package is installed on every
# host that imports ../../home (macbook and hetztop, not cros), and the
# OpenCode config is patched to run it.
#
# Secrets: the server reads KAGI_AUTH_TOKEN from the environment. The
# wrapper below loads it from a file if present, so the token never enters
# the nix store or the repository. Two locations are checked in order:
#
#   /run/agenix/kagi-token   -- agenix-decrypted secret (macbook, hetztop)
#   $HOME/.config/kagi/token -- plain file for quick local use
#
# To use agenix:
#
#   cd secrets
#   nix run --file .. pkgs.agenix -- -e kagi-token.age -i identity.age
#   # paste the token, save, then add to hosts/*/default.nix:
#   #   age.secrets.kagi-token = { file = ../../secrets/kagi-token.age; owner = "lillecarl"; mode = "0400"; };
#   # and rekey: nix run --file .. pkgs.agenix -- -r -i identity.age
#
# The plain file alternative is one command and no rebuild:
#
#   mkdir -p ~/.config/kagi && echo -n "token" > ~/.config/kagi/token && chmod 600 ~/.config/kagi/token
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Wrapper that loads KAGI_AUTH_TOKEN from a file if the environment does
  # not already have it. This keeps the token out of opencode.json and out
  # of the nix store; opencode's mcp.environment therefore stays empty.
  kagiWrapped = pkgs.writeShellApplication {
    name = "kagi-mcp-wrapped";
    runtimeInputs = [
      pkgs.kagi-mcp
      pkgs.coreutils
    ];
    text = ''
      if [ -z "''${KAGI_AUTH_TOKEN:-}" ]; then
        if [ -f /run/agenix/kagi-token ]; then
          KAGI_AUTH_TOKEN="$(cat /run/agenix/kagi-token)"
          export KAGI_AUTH_TOKEN
        elif [ -f "''${HOME}/.config/kagi/token" ]; then
          KAGI_AUTH_TOKEN="$(cat "''${HOME}/.config/kagi/token")"
          export KAGI_AUTH_TOKEN
        fi
      fi
      exec kagi-mcp "$@"
    '';
  };

  # Merges `mcp.kagi` into ~/.config/opencode/opencode.json, touching
  # nothing else in the file. Same read-modify-write pattern as
  # ./opencode.nix for `instructions`, so a crash never leaves the file
  # truncated. The rest of opencode.json stays hand-managed.
  # E231 and E501: the `expected` dict holds a store path, one long line
  # with no spaces after commas. Both are deliberate.
  patchKagiMcp = pkgs.writers.writePython3Bin "opencode-patch-kagi-mcp" { flakeIgnore = [ "E231" "E501" ]; } ''
    import json
    import os

    expected = {
        "type": "local",
        "command": ["${lib.getExe kagiWrapped}"],
        "enabled": True,
    }


    def main() -> None:
        path = os.path.expanduser("~/.config/opencode/opencode.json")
        try:
            with open(path) as f:
                cfg = json.load(f)
        except FileNotFoundError:
            cfg = {}
        except json.JSONDecodeError:
            cfg = {}

        mcp = cfg.get("mcp")
        if not isinstance(mcp, dict):
            mcp = {}
            cfg["mcp"] = mcp

        if mcp.get("kagi") == expected:
            return
        mcp["kagi"] = expected

        tmp_path = path + ".tmp"
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(tmp_path, "w") as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, path)


    if __name__ == "__main__":
        main()
  '';
in
{
  home.packages = [
    pkgs.kagi-mcp
    kagiWrapped
  ];

  home.activation.opencodeKagiMcp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p "$HOME/.config/opencode"
    run ${lib.getExe patchKagiMcp}
  '';
}
