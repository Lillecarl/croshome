{
  config,
  lib,
  selfStr,
  ...
}:
let
  # This configuration is personal, so it commits under the personal address
  # even though the default is now the work one. Add a path here to give
  # another repo the same treatment.
  personalRepos = [ selfStr ];
  personalEmail = "git@lillecarl.com";
in
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

        # jj does not read git's config for the committer identity. Checked
        # in a colocated repo: a [user] section written straight into
        # .git/config changed nothing, and jj stamped its own value on the
        # commit. So this scope is the only thing that moves the address for
        # a single repo, and the git block below is for git's benefit alone.
        "--scope" = [
          {
            "--when".repositories = personalRepos;
            user.email = personalEmail;
          }
        ];
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

      # The same exception, for git's own sake. Nothing here uses git to
      # commit, but the address it would use should not be the work one
      # either. gitdir: needs the trailing slash to match a directory.
      includes = map (repo: {
        condition = "gitdir:${repo}/";
        contents.user.email = personalEmail;
      }) personalRepos;
    };
  };
}
