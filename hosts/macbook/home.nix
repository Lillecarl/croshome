{ pkgs, ... }:
let
  # Homebrew 6 refuses to load a cask from a tap nobody has vouched for, and
  # `brew bundle` failing takes the whole activation with it. The tap named
  # here is the one ./fuse.nix adds; `brew trust` writes exactly this file.
  brewTrust = pkgs.writeText "homebrew-trust.json" (
    builtins.toJSON { trustedtaps = [ "macos-fuse-t/cask" ]; }
  );
in
{
  imports = [ ../../home ];

  home.username = "lillecarl";
  home.homeDirectory = "/Users/lillecarl";
  home.stateVersion = "26.11";

  # Both locations, because brew picks between them from the environment: it
  # uses $XDG_CONFIG_HOME/homebrew when that is set, which is the case in a
  # shell, and ~/.homebrew otherwise -- and activation runs brew under sudo,
  # which resets the environment down to PATH.
  home.file.".homebrew/trust.json".source = brewTrust;
  xdg.configFile."homebrew/trust.json".source = brewTrust;

  # See ../../home/wrapty.nix -- puts wrapty on PATH for the Claude Code
  # plugin under home/claude/skills/wrapty. Also on hetztop; not on cros,
  # which does not import ../../home at all.
  programs.wrapty.enable = true;

  # See ../../home/claude-md.nix -- generates ~/.claude/CLAUDE.md. Only the
  # values that differ per machine live here; the prose is shared.
  programs.claudeInstructions = {
    enable = true;
    hostName = "macbook";
    cloneDir = "~/Dynamist";
  };

  home.packages = [
    # The CLI only. Pulling from lillecarl.cachix.org is already set up as a
    # substituter in ./default.nix; this is for pushing, and it keeps its auth
    # token in ~/.config/cachix/cachix.dhall, which stays hand-managed.
    pkgs.cachix
    pkgs.autossh
  ];
}
