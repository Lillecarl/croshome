{
  pkgs,
  lib,
  inputs,
  system,
  ...
}:
{
  imports = [
    ./emacs.nix
    ./fonts.nix
    ./foot.nix
  ];

  # Only what genuinely cannot work on macOS belongs here. Availability was
  # checked rather than guessed: wireguard-tools, sbomnix and the agent CLIs
  # all build for darwin, so they are in ../packages.nix and ../agents.nix.
  home.packages = with pkgs; [
    # inotify is a Linux kernel API with no macOS equivalent in this package.
    inotify-tools
    # Wayland: the protocol proxy and the clipboard tool. The MacBook reaches
    # Linux applications through Cocoa-Way, which brings its own waypipe, and
    # its clipboard is pbcopy -- see home/fish/functions/copy.fish.
    waypipe
    wl-clipboard

    # Builds on darwin but then fails its own --version check, so the binary
    # upstream ships for macOS is not the one this expects.
    inputs.llm-agents.packages.${system}.kilocode-cli

    # Upstream publishes a plain CLI tarball for Linux only -- the sole macOS
    # asset is opencode-desktop-mac-*.app.tar.gz, which is the desktop
    # application. The llm-agents package does not build for darwin either, so
    # there is nothing to share and this stays whole.
    (
      let
        release = builtins.fromJSON (
          builtins.readFile (
            builtins.fetchurl {
              url = "https://api.github.com/repos/anomalyco/opencode/releases/latest";
              name = "opencode-latest-release.json";
            }
          )
        );
        tag = release.tag_name;
        arch = if pkgs.stdenv.hostPlatform.isx86_64 then "x64" else "arm64";
      in
      inputs.llm-agents.packages.${system}.opencode.overrideAttrs {
        version = lib.strings.removePrefix "v" tag;
        src = builtins.fetchurl {
          url = "https://github.com/anomalyco/opencode/releases/download/${tag}/opencode-linux-${arch}.tar.gz";
          name = "opencode-${tag}.tar.gz";
        };
      }
    )
  ];
}
