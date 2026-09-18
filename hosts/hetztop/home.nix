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

  # See ../../home/agent-machine.nix -- the machine section every harness
  # reads. Only the values that differ per machine live here.
  programs.agentMachine = {
    enable = true;
    hostName = "hetztop";
    cloneDir = "~/Code";
    extraRebuildNotes = ''

      `ai-rebuild-pynixd` builds the same attribute through the pynixd
      store instead of the daemon. Use it only when I ask for it by name.
    '';
  };

  # See ../../home/claude-md.nix -- generates ~/.claude/CLAUDE.md. Shared
  # prose, read live out of the checkout through `@` imports.
  programs.claudeInstructions.enable = true;

  # See ../../home/codex-md.nix -- generates ~/.codex/AGENTS.md. Shared prose
  # only, inlined at build time; Codex has no import mechanism.
  programs.codexInstructions.enable = true;
}
