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

  # The PreToolUse hook that blocks git writes in a jj repo, built rather than
  # executed straight out of the tree.
  #
  # This pins the *interpreter* and nothing else. The shebang was
  # `#!/usr/bin/env python3`, which resolves against whatever python the
  # environment happens to have -- and hetztop has none, so the hook could not
  # run at all there. That dependency is accidental: the script does not care
  # which python it gets, only that it gets one.
  #
  # The `jj` lookup it does at runtime is deliberately NOT pinned, and that is
  # the whole point of the hook. It asks the environment two questions -- is
  # there a jj, and is this a jj repo -- and a "no" to either means git is
  # nobody's business here and the command is allowed through. Putting jj on
  # this wrapper's PATH would answer the first question yes everywhere and
  # make that case unreachable. git is banned in jj repos, not in general.
  #
  # ./claude/skills/jj-worktrees/hooks/hooks.json names this by bare command,
  # the same arrangement ./wrapty.nix uses for wrapty's hooks. A store path
  # there is not an option: the skills directory is one out-of-store symlink,
  # so no file inside it can be nix-generated.
  #
  # The cost is that this one script no longer follows the "edit takes effect
  # immediately" rule the rest of that directory does -- changing it now needs
  # a rebuild.
  jjBlockGitWrite =
    let
      source = ./claude/skills/jj-worktrees/scripts/pretooluse-block-git-write.py;

      # writePython3Bin writes its own shebang against a pinned interpreter.
      # Leaving the original would make it the second line of the file, which
      # the flake8 pass reads as a stray block comment (E265).
      body = lib.removePrefix "#!/usr/bin/env python3\n" (builtins.readFile source);

      # E501 alone: the long lines there are deliberate -- compact set
      # literals and prose. Every other flake8 check stays on, and catches a
      # genuine syntax error at build time rather than at hook time.
      built = pkgs.writers.writePython3Bin "jj-block-git-write" { flakeIgnore = [ "E501" ]; } body;
    in
    # Deciding whether a command *is* an invocation is now a small shell
    # parser, and its failure mode is refusing legitimate commands -- which is
    # both worse than missing one and much less likely to be noticed. So its
    # cases run here, against the built copy, and a regression is a failed
    # build. Copied rather than symlinked so $out is a package in its own
    # right and the check cannot be skipped by depending on `built` directly.
    pkgs.runCommand "jj-block-git-write" { } ''
      ${lib.getExe pkgs.python3} ${./claude/skills/jj-worktrees/scripts/test_block_git_write.py} \
        ${built}/bin/jj-block-git-write
      mkdir -p $out/bin
      cp ${built}/bin/jj-block-git-write $out/bin/jj-block-git-write
    '';
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
    jjBlockGitWrite

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
