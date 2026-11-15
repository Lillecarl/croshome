# runix-agent beside the plain Claude Code setup, as `rclaude`. It runs
# against ~/.rclaude with its own login, so `claude` and ~/.claude stay as
# they are. The tools come from this configuration's inputs, and reach
# Claude Code only through the wrapper's PATH.
{ inputs, ... }:
{
  imports = [ (inputs.runix-agent.outPath + "/nix/home-manager.nix") ];

  programs.runix-agent = {
    enable = true;
    imports = [ (inputs.runix-agent.outPath + "/examples/lillecarl/module.nix") ];

    lillecarl = {
      enable = true;
      machine = {
        hostName = "lillecarl@dynhetz";
        configuration = "/home/lillecarl/Code/croshome";
        rebuildCommand = "ai-rebuild";
        builderUser = "lillecarl";
      };
      nixidae.src = inputs.nixidae;
      phabfive.src = inputs.phabfive;
      pyedit.src = inputs.pyedit;
      pyjj.src = inputs.pyjj;
      pymux.src = inputs.pyterm;
    };

    claude = {
      enable = true;
      wrap = {
        name = "rclaude";
        mode = "configDir";
        configDir = "$HOME/.rclaude";
      };
    };
  };
}
