{ osConfig, pkgs, ... }:
{
  imports = [ ../../home ];

  # The vendored xonsh bundle, built by the overlay entry of the same name
  # (../../pkgs/default.nix). Installed but deliberately not made anyone's
  # shell: it is still rounds away from ready, and fish stays users.users'
  # shells.lillecarl.shell until it is. Launch it as `anyxonsh` to try it.
  home.packages = [ pkgs.anyxonsh ];

  # There is a NixOS underneath this one, so take its stateVersion rather than
  # keep a second copy that can drift from it.
  home.stateVersion = osConfig.system.stateVersion;

  # See ../../home/wrapty.nix -- puts wrapty on PATH so ../../home/fish/
  # functions/claude.fish routes `claude` through it, and so the Claude Code
  # plugin manifest under ../../home/claude/skills/wrapty can name its
  # binaries bare.
  programs.wrapty.enable = true;

  # See ../../home/claude-md.nix -- generates ~/.claude/CLAUDE.md. Only the
  # values that differ per machine live here; the prose is shared.
  programs.claudeInstructions = {
    enable = true;
    hostName = "dynhetz";
    cloneDir = "~/Code";
  };
}
