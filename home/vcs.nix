{ config, selfStr, ... }:
{
  config = {
    programs.jujutsu = {
      enable = true;
      settings = {
        user.name = "lillecarl";
        user.email = "git@lillecarl.com";
        git.private-commits = "description(glob:'private:*')";
      };
    };
    programs.jjui = {
      enable = true;
      settings = { };
    };
    xdg.configFile."jjui".source = config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/jjui";

    programs.git = {
      enable = true;
      settings = {
        user.name = config.programs.jujutsu.settings.user.name;
        user.email = config.programs.jujutsu.settings.user.email;
      };
    };
  };
}
