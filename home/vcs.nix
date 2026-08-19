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
        # The work address, on every machine. It used to default to
        # git@lillecarl.com with only the MacBook overriding it, which meant
        # work landed under a personal address from anywhere else.
        #
        # mkDefault stays, so a host can still commit under another address.
        # The git identity below reads this value, so overriding it moves
        # both.
        user.email = lib.mkDefault "carl.andersson@dynamist.se";
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
