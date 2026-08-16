{
  config,
  lib,
  pkgs,
  inputs,
  system,
  selfStr,
  ...
}:
let
  inherit (pkgs.stdenv) hostPlatform;

  # versionCheckPhase runs the built binary and looks for the version in its
  # output. On darwin the two CLIs below produce no output at all inside the
  # build sandbox, from neither --version nor --help. Run the same store path
  # outside the sandbox and it prints its version and exits 0, so the check is
  # measuring the sandbox rather than the package. Linux keeps the check.
  #
  # This is why both were in ./linux until now: the build failed, and a failed
  # build reads as "does not work here". Running the binary is what separates
  # the two, and neither of these needed to be Linux-only.
  runsOnDarwinButFailsTheCheck = drv: drv.overrideAttrs { doInstallCheck = !hostPlatform.isDarwin; };
in
{
  # Out-of-store symlinks, so editing a skill takes effect immediately rather
  # than after a rebuild. Both agents read the same directory: a skill is
  # prose, and nothing in it is Claude-specific.
  home.file.".claude/skills".source =
    config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/claude/skills";
  home.file.".gemini/skills".source =
    config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/claude/skills";

  home.packages = [
    # The overlay in ../pkgs tracks upstream releases rather than the nixpkgs
    # pin, and picks the build for the host platform, so this one attribute
    # works on macOS and Linux alike.
    pkgs.claude-code
    pkgs.codex # OpenAI
    pkgs.fabric-ai

    # MCP servers
    pkgs.context7-mcp
    pkgs.mcp-gateway
    pkgs.mcp-nixos
    pkgs.playwright-mcp

    # Every agent CLI here runs on macOS and Linux alike. Each was built for
    # aarch64-darwin and then run, because meta.platforms says only that a
    # package is allowed on a platform, and a green build says only that it
    # compiled -- neither says the binary works.
    inputs.acpcli.packages.${system}.acpcli
    inputs.llm-agents.packages.${system}.antigravity-cli
    inputs.llm-agents.packages.${system}.reasonix
    (runsOnDarwinButFailsTheCheck inputs.llm-agents.packages.${system}.kilocode-cli)

    # Upstream ships a plain CLI for both platforms -- opencode-linux-*.tar.gz
    # and opencode-darwin-*.zip -- so this is one package with two asset names.
    # The opencode-desktop-* assets are the desktop application and are a
    # different thing entirely.
    #
    # Tracks the latest release rather than the llm-agents pin, which lags far
    # enough behind that its own versionCheckPhase fails against it.
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
        arch = if hostPlatform.isx86_64 then "x64" else "arm64";
        os = if hostPlatform.isDarwin then "darwin" else "linux";
        ext = if hostPlatform.isDarwin then "zip" else "tar.gz";
      in
      (runsOnDarwinButFailsTheCheck inputs.llm-agents.packages.${system}.opencode).overrideAttrs {
        version = lib.strings.removePrefix "v" tag;
        src = builtins.fetchurl {
          url = "https://github.com/anomalyco/opencode/releases/download/${tag}/opencode-${os}-${arch}.${ext}";
          name = "opencode-${tag}.${ext}";
        };
      }
    )
  ];
}
