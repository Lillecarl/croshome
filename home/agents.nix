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

  # One PreToolUse hook script, built rather than executed straight out of the
  # tree. ./claude/skills/jj-worktrees/scripts holds two of them, and
  # `jjAgentHooks` below builds both with this.
  #
  # This pins the *interpreter* and nothing else. The shebang was
  # `#!/usr/bin/env python3`, which resolves against whatever python the
  # environment happens to have -- and hetztop has none, so a hook could not
  # run at all there. That dependency is accidental: neither script cares
  # which python it gets, only that it gets one.
  #
  # The `jj` lookup the git-write hook does at runtime is deliberately NOT
  # pinned, and that is the whole point of it. It asks the environment two
  # questions -- is there a jj, and is this a jj repo -- and a "no" to either
  # means git is nobody's business here and the command is allowed through.
  # Putting jj on this wrapper's PATH would answer the first question yes
  # everywhere and make that case unreachable. git is banned in jj repos, not
  # in general.
  #
  # ./claude/skills/jj-worktrees/hooks/hooks.json names both by bare command,
  # the same arrangement ./wrapty.nix uses for wrapty's hooks. A store path
  # there is not an option: the skills directory is one out-of-store symlink,
  # so no file inside it can be nix-generated.
  #
  # The cost is that these two scripts no longer follow the "edit takes effect
  # immediately" rule the rest of that directory does -- changing one now needs
  # a rebuild.
  #
  # Adding a hook is a third thing again, and slower than either. A rebuild
  # reaches the *script* at once, because hooks.json names a bare command and
  # PATH is re-resolved every time one runs. It does not reach hooks.json
  # itself: a session reads that file when it loads the plugin, so a session
  # already running keeps the list it started with. Measured on the trailer
  # hook -- the binary refused the command when fed it directly, and the same
  # command went through the session that had just built it.
  #
  # So a session that loaded the plugin before an entry existed does not run
  # it. Whether `/reload-plugins` picks a new entry up was not tested; a new
  # session certainly does.
  #
  # writePython3Bin writes its own shebang against a pinned interpreter.
  # Leaving the original would make it the second line of the file, which the
  # flake8 pass reads as a stray block comment (E265).
  #
  # E501 alone: the long lines in these are deliberate -- compact set literals
  # and prose. Every other flake8 check stays on, and catches a genuine syntax
  # error at build time rather than at hook time.
  buildHook =
    name: source:
    pkgs.writers.writePython3Bin name { flakeIgnore = [ "E501" ]; } (
      lib.removePrefix "#!/usr/bin/env python3\n" (builtins.readFile source)
    );

  # Both PreToolUse hooks, in one bin/.
  #
  # One package rather than two, because pretooluse-block-trailers.py imports
  # its shell parsing from pretooluse-block-git-write.py at runtime, and finds
  # it by looking in its own directory. Two `writePython3Bin` outputs are two
  # store paths, so the lookup would fail and the trailer hook would allow
  # everything -- silently, since a hook that finds no parser allows rather
  # than refuses. Here they are neighbours, and the test below proves the
  # import resolves.
  #
  # Deciding whether a command *is* an invocation is a small shell parser, and
  # its failure mode is refusing legitimate commands -- which is both worse
  # than missing one and much less likely to be noticed. So the cases run
  # here, against the built copies, and a regression is a failed build. Copied
  # rather than symlinked so $out is a package in its own right and the checks
  # cannot be skipped by depending on the built scripts directly.
  jjAgentHooks =
    let
      scripts = ./claude/skills/jj-worktrees/scripts;
      gitWrite = buildHook "jj-block-git-write" "${scripts}/pretooluse-block-git-write.py";
      trailers = buildHook "jj-block-trailers" "${scripts}/pretooluse-block-trailers.py";
    in
    pkgs.runCommand "jj-agent-hooks" { } ''
      mkdir -p $out/bin
      cp ${gitWrite}/bin/jj-block-git-write $out/bin/jj-block-git-write
      cp ${trailers}/bin/jj-block-trailers $out/bin/jj-block-trailers

      # The trailer test imports its neighbour out of $out/bin, and python
      # writes a __pycache__ beside whatever it imports. Left on, that
      # directory ends up in the store path next to the two binaries.
      export PYTHONDONTWRITEBYTECODE=1

      ${lib.getExe pkgs.python3} ${scripts}/test_block_git_write.py \
        $out/bin/jj-block-git-write
      ${lib.getExe pkgs.python3} ${scripts}/test_block_trailers.py \
        $out/bin/jj-block-trailers
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
    jjAgentHooks

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
