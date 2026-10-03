{ pkgs, ... }:
let
  brew-update = pkgs.writeShellApplication {
    name = "brew-update";
    text = ''
      set -euo pipefail

      # Occasional hand-driven update of everything Homebrew manages:
      # refresh taps, upgrade (arguments forward to `brew upgrade`, so
      # `brew-update --greedy` also refreshes self-updating casks), drop
      # unused dependencies, prune the cache. Activation never does any of
      # this (auto-update and upgrade both default off), so this script is
      # the only thing that moves cask versions.
      brew_bin="$(command -v brew || true)"
      if [ -z "$brew_bin" ] && [ -x /opt/homebrew/bin/brew ]; then
        brew_bin=/opt/homebrew/bin/brew
      fi
      if [ -z "$brew_bin" ]; then
        echo "brew-update: homebrew not installed" >&2
        exit 1
      fi

      "$brew_bin" update
      "$brew_bin" upgrade "$@"
      "$brew_bin" autoremove
      "$brew_bin" cleanup
    '';
  };
in
{
  # Beaten path for GUI apps: vendor-signed casks through Homebrew. macOS
  # grants privacy entitlements per signing identity, so a repackaged
  # bundle reads as a different app -- the unsigned nix firefox-bin could
  # not initialize any profile under macOS 27.
  homebrew = {
    enable = true;
    casks = [
      "chatgpt"
      "claude"
      "firefox"
      "fuse-t"
      "kitty"
      "nextcloud"
      "paseo"
      "slack"
      "stremio"
      "winbox"
    ];
  };

  environment.systemPackages = [
    brew-update
  ];
}
