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
  # `agentHooks` below builds all three with this.
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
  # the same arrangement ./wrapty.nix uses for wrapty's hooks. That was forced
  # while the skills directory was one out-of-store symlink and nothing inside
  # it could be nix-generated. It no longer is, so a store path there is now
  # possible and is the better answer: hooks.json would name an exact build
  # rather than whatever PATH resolves to.
  #
  # Bare commands still have one property a store path does not. PATH is
  # re-resolved on every invocation, so a rebuild reaches a running session's
  # hook scripts at once; a store path in hooks.json would not, because a
  # session reads that file when it loads the plugin.
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

  # Every PreToolUse hook, in one bin/.
  #
  # One package rather than three, because two of them import their shell
  # parsing from pretooluse-block-git-write.py at runtime, and find it by
  # looking in their own directory. Separate `writePython3Bin` outputs are
  # separate store paths, so the lookup would fail and those hooks would allow
  # everything -- silently, since a hook that finds no parser allows rather
  # than refuses. Here they are neighbours, and the tests below prove the
  # import resolves.
  #
  # The pgrep guard belongs to wrapty's plugin, not jj's -- a `pgrep -f` loop
  # is a session that hangs -- but it is built here for that same neighbour
  # rule, and its hooks.json lives with wrapty. It is deliberately not a
  # console script of pkgs.wrapty either: the wrapty wrapper puts its own
  # store bin/ at the front of PATH, so a running session keeps the binaries
  # it started with and a new name there would not resolve until it restarts.
  #
  # Deciding whether a command *is* an invocation is a small shell parser, and
  # its failure mode is refusing legitimate commands -- which is both worse
  # than missing one and much less likely to be noticed. So the cases run
  # here, against the built copies, and a regression is a failed build. Copied
  # rather than symlinked so $out is a package in its own right and the checks
  # cannot be skipped by depending on the built scripts directly.
  agentHooks =
    let
      scripts = ./claude/skills/jj-worktrees/scripts;
      wraptyScripts = ./claude/skills/wrapty/scripts;
      gitWrite = buildHook "jj-block-git-write" "${scripts}/pretooluse-block-git-write.py";
      trailers = buildHook "jj-block-trailers" "${scripts}/pretooluse-block-trailers.py";
      pgrep = buildHook "agent-block-pgrep" "${wraptyScripts}/pretooluse-block-pgrep.py";
      pythonEdit = buildHook "agent-block-python-edit" "${wraptyScripts}/pretooluse-block-python-edit.py";
    in
    pkgs.runCommand "agent-hooks" { } ''
      mkdir -p $out/bin
      cp ${gitWrite}/bin/jj-block-git-write $out/bin/jj-block-git-write
      cp ${trailers}/bin/jj-block-trailers $out/bin/jj-block-trailers
      cp ${pgrep}/bin/agent-block-pgrep $out/bin/agent-block-pgrep
      cp ${pythonEdit}/bin/agent-block-python-edit $out/bin/agent-block-python-edit

      # The trailer test imports its neighbour out of $out/bin, and python
      # writes a __pycache__ beside whatever it imports. Left on, that
      # directory ends up in the store path next to the two binaries.
      export PYTHONDONTWRITEBYTECODE=1

      ${lib.getExe pkgs.python3} ${scripts}/test_block_git_write.py \
        $out/bin/jj-block-git-write
      ${lib.getExe pkgs.python3} ${scripts}/test_block_trailers.py \
        $out/bin/jj-block-trailers
      ${lib.getExe pkgs.python3} ${wraptyScripts}/test_block_pgrep.py \
        $out/bin/agent-block-pgrep
      ${lib.getExe pkgs.python3} ${wraptyScripts}/test_block_python_edit.py \
        $out/bin/agent-block-python-edit
    '';

  # `synced` is not a skill. It is the bucket Claude Code writes its
  # claude.ai skill sync into, and it is left out so that sync lands in
  # $HOME. Linked like the rest, it wrote 4M of Anthropic's own skills into
  # this repository.
  repoSkills = lib.attrNames (
    lib.filterAttrs (name: type: type == "directory" && name != "synced") (
      builtins.readDir ./claude/skills
    )
  );

  repoSkillLinks =
    agentDir:
    lib.listToAttrs (
      map (name: {
        name = "${agentDir}/skills/${name}";
        value.source = ./claude/skills + "/${name}";
      }) repoSkills
    );

  # The skill pyedit generates during its own build. Nothing distinguishes it
  # from the repo's own skills above any more -- both are store paths. The
  # double name is the nixpkgs convention, share/skills/$pname/<skill>, so a
  # package can ship several.
  pyeditSkillLink = agentDir: {
    "${agentDir}/skills/pyedit".source = "${pkgs.pyedit}/share/skills/pyedit/pyedit";
  };
in
{
  # One store path per skill. Both agents read the same set: a skill is
  # prose, and nothing in it is Claude-specific.
  #
  # Editing a skill needs `ai-rebuild` before the next session sees it. That
  # is the trade for a skill being content-addressed like everything else
  # here, and for a package being able to ship one: the directory holds
  # exactly what the configuration says it holds.
  #
  # One entry per skill rather than one for the directory, and the directory
  # itself stays real and writable. Claude Code writes its claude.ai skill
  # sync into ~/.claude/skills/synced, so a store-owned directory there would
  # break that sync outright.
  #
  # A host still on the old shape needs one manual step. home-manager does
  # not replace a managed symlink with a managed directory: it leaves
  # ~/.claude/skills and ~/.gemini/skills pointing at the old generation, and
  # the per-skill links never appear. Delete both symlinks, then activate.
  # Nothing is lost -- they are links into the store.
  home.file =
    repoSkillLinks ".claude"
    // repoSkillLinks ".gemini"
    // pyeditSkillLink ".claude"
    // pyeditSkillLink ".gemini";

  # Single keys merged into ~/.claude/settings.json. Every other key stays as
  # Claude Code wrote it; ./wrapty.nix explains why the file is not generated
  # whole.
  home.mergedFile.".claude/settings.json" = {
    format = "json";
    settings = {
      # Starts the Remote Control bridge in every session. Without it the
      # bridge waits for `claude remote-control` or the /config toggle.
      remoteControlAtStartup = true;

      # Replaces the Co-Authored-By and Claude-Session lines Claude Code
      # injects by default, which ./agents/shared/commits.md then has to
      # argue with every session.
      #
      # Claude Code does no substitution here, so `$model` reaches the
      # reminder literally and the reading model resolves it. That is the
      # whole point: one trailer, named per model, without this file
      # knowing which model runs.
      #
      # `commit` must stay non-empty. Set it to "" and the reminder inverts
      # into "do not add attribution lines ... applies even if a CLAUDE.md
      # or memory rule asks for attribution lines", which fights
      # ./agents/shared/commits.md instead of agreeing with it.
      attribution = {
        commit = "Assisted-By: Claude $model";
        pr = "";
        sessionUrl = false;
      };

      # Auto mode otherwise adds a paragraph telling the model to edit files
      # with sed and heredocs, against ./agents/shared/tools.md. The steer
      # has no settings key of its own, only this environment variable, read
      # as 1/true/yes/on against 0/false/no/off. Auto mode itself stays on.
      env.CLAUDE_CODE_THRIFTY_SONIC = "0";
    };
  };

  home.packages = [
    agentHooks

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
