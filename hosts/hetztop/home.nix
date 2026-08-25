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
  # settings.json and touches nothing else there. Nothing further is needed to
  # load the plugin: see ../../home/wrapty.nix for why `enabledPlugins` is not
  # the gate it looks like.
  programs.wrapty.enable = true;

  # See ../../home/claude-md.nix -- generates ~/.claude/CLAUDE.md. Only the
  # values that differ per machine live here; the prose is shared.
  programs.claudeInstructions = {
    enable = true;
    hostName = "hetztop";
    cloneDir = "~/Code";
    extraRebuildNotes = ''

      `ai-rebuild-pynixd` builds the same attribute through the pynixd
      store instead of the daemon. Use it only when I ask for it by name.
    '';
  };
}
