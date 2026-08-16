{
  config,
  lib,
  selfStr,
  ...
}:
{
  config = {
    programs.jujutsu = {
      enable = true;
      settings = {
        user.name = "lillecarl";
        # mkDefault so a host can commit under another address. The git
        # identity below reads this value, so overriding it moves both.
        user.email = lib.mkDefault "git@lillecarl.com";
        git.private-commits = "description(glob:'private:*')";
        ui.pager = [
          "sh"
          "-c"
          "exec \${PAGER:-less -FRX}"
        ];
        merge-tools.jj-hunk = {
          program = "jj-hunk";
          edit-args = [
            "select"
            "$left"
            "$right"
          ];
        };
      };
    };
    programs.jjui = {
      enable = true;
      settings = { };
    };
    xdg.configFile."jjui".source = config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/jjui";

    programs.git = {
      enable = true;
      ignores = [
        "CLAUDE.local.md"
        "**/.claude/settings.local.json"
      ];
      settings = {
        user.name = config.programs.jujutsu.settings.user.name;
        user.email = config.programs.jujutsu.settings.user.email;
      };
    };
  };
}
