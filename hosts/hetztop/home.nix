{ osConfig, ... }:
{
  imports = [ ../../home ];

  # There is a NixOS underneath this one, so take its stateVersion rather than
  # keep a second copy that can drift from it.
  home.stateVersion = osConfig.system.stateVersion;

  # See ../../home/wrapty.nix -- puts wrapty on PATH so ../../home/fish/
  # functions/claude.fish routes `claude` through it, and so the Claude Code
  # plugin manifest under ../../home/claude/skills/wrapty can name its
  # binaries bare. Verified to build and run on x86_64-linux.
  #
  # The module's activation step merges `statusLine` into ~/.claude/
  # settings.json, but `enabledPlugins` is not nix-managed and still has to be
  # set by hand, once:
  #
  #   "enabledPlugins": { "wrapty@skills-dir": true }
  programs.wrapty.enable = true;
}
