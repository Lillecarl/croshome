{
  config,
  pkgs,
  selfStr,
  ...
}:
{
  # emacs-pgtk is a pure-GTK build and draws on Wayland, so this is a Linux
  # module rather than a shared one. macOS would need a different package
  # (emacs-macport) and a different frame setup, and there is no Emacs on the
  # MacBook today, so nothing tries to paper over the difference here.
  programs.emacs = {
    enable = true;
    package = pkgs.emacs-pgtk;
    extraPackages =
      ep: with ep; [
        which-key
        vterm
        meow
        (trivialBuild {
          pname = "meow-vterm";
          version = "0-unstable";
          src = pkgs.fetchFromGitHub {
            owner = "accelbread";
            repo = "meow-vterm";
            rev = "fc7e86a268b523ca12ff451e91aabe5485fbc975";
            hash = "sha256-oWWnyxTT/xdMq4CxLKb8BtjsPajg5sMctOq4dPHZzJk=";
          };
          packageRequires = [
            meow
            vterm
          ];
        })
        consult
        vertico
        orderless
        nix-mode
        nix-ts-mode
        clipetty
        multiple-cursors
        catppuccin-theme
        corfu
        corfu-terminal
        cape
        treesit-grammars.with-all-grammars
      ];
  };

  # Out-of-store symlinks: elisp is edited and re-evaluated in place, and a
  # rebuild between the two would defeat the point.
  home.file.".emacs.d/init.el".source =
    config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/emacs/init.el";
  home.file.".emacs.d/early-init.el".source =
    config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/emacs/early-init.el";
  home.file.".emacs.d/config".source =
    config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/emacs/config";
}
