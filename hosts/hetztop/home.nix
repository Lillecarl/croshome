{ osConfig, ... }:
{
  imports = [ ../../home ];

  # There is a NixOS underneath this one, so take its stateVersion rather than
  # keep a second copy that can drift from it.
  home.stateVersion = osConfig.system.stateVersion;

  # See ../../modules/home/agent-machine.nix -- the machine section every harness
  # reads. Only the values that differ per machine live here.
  programs.agentMachine = {
    hostName = "hetztop";
    cloneDir = "~/Code";
    extraRebuildNotes = ''

      `ai-rebuild-pynixd` builds the same attribute through the pynixd
      store instead of the daemon. Use it only when I ask for it by name.
    '';
  };
}
