# Builds ~/.claude/CLAUDE.md, the global instruction file Claude Code reads
# before every session on this machine.
#
# The file is half generated and half live. The header below is generated,
# because it states things that differ per machine: the clone directory, the
# rebuild command, and which nix-community builder matches this system. The
# sections after it are plain markdown in ./agents/, pulled in with `@`
# imports that point straight into the checkout. ./agents/shared holds rules
# shared with the other harnesses (see ./opencode.nix); ./agents/claude holds
# what only Claude Code needs. An edit to one of those files applies to the
# next session with no rebuild. An edit here needs one.
#
# That split is deliberate. Prose changes often and structure does not, so
# the part that changes often stays out of the store. It is the same trade
# ./agents.nix makes for the skills directory, for the same reason.
#
# ~/.claude/settings.json stays hand-managed: see ./wrapty.nix for why.
{
  config,
  lib,
  pkgs,
  selfStr,
  ...
}:
let
  cfg = config.programs.claudeInstructions;

  system = pkgs.stdenv.hostPlatform.system;

  # https://nix-community.org, docs/community-builders.md. One public builder
  # per system. `kvm` and `nixos-test` are Linux features, so the darwin box
  # must not claim them: a builder line that claims a feature the machine
  # lacks makes nix send it work that then fails there.
  builders = {
    "x86_64-linux" = {
      host = "build-box.nix-community.org";
      features = "kvm,nixos-test,benchmark,big-parallel";
    };
    "aarch64-linux" = {
      host = "aarch64-build-box.nix-community.org";
      features = "kvm,nixos-test,benchmark,big-parallel";
    };
    "aarch64-darwin" = {
      host = "darwin-build-box.nix-community.org";
      features = "benchmark,big-parallel";
    };
  };

  native = builders.${system} or null;

  builderLine =
    b: "lillecarl@${b.host} ${system} - 12 1 ${b.features}";

  # Every builder, so an agent cross-building for another system can find the
  # right host without being told. The native one is named separately above.
  builderTable = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      sys: b:
      "| `${sys}` | `${b.host}`${lib.optionalString (sys == system) " *(this machine)*"} |"
    ) builders
  );

  remoteBuilders = lib.optionalString (native != null) ''
    ## Nix remote builders

    nix-community runs a public builder for each system. This machine builds
    `${system}`, so its own builds go to `${native.host}`.

    ```
    --max-jobs 0 --builders '${builderLine native}' --print-build-logs
    ```

    | system | builder |
    | --- | --- |
    ${builderTable}

    The `12 1` in that line is a choice, not a property of the box. It caps
    the jobs you send and sets the speed factor.

    **Do not use a builder by default.** These are shared nix-community
    machines, not personal infrastructure, so they take only work that needs
    them. Use one when I ask for it by name. Ask me first when a build is
    heavy enough that this machine would struggle: nix itself, a full
    kube-apiserver validation run, or a large closure from scratch.

    Prefer a plain local `nix build` otherwise. `--max-jobs 0` turns off local
    builds, so nothing builds at all if the builder is unreachable. Never add
    the flag speculatively.

    Do not send a build that touches secrets. nix-community documents the
    reason: every trusted user of a builder can write to its store, so you
    cannot trust what comes back for anything sensitive.

    A builder's host key must be in `known_hosts` before a build can use it.
    Builds go through the nix daemon, which connects as root. So a "Host key
    verification failed" here means `/root/.ssh/known_hosts` lacks the entry,
    not my own `~/.ssh`.

    These builds take many minutes. Run them in the background and read the
    log file. Do not block on them.
  '';

  header = ''
    # Global preferences

    Nix generates this file. Do not edit `~/.claude/CLAUDE.md`: it is a
    read-only store symlink, and the next rebuild replaces it.

    Edit the configuration instead, at `${selfStr}`.

    - The sections in this header come from `home/claude-md.nix`. A change to
      one of them needs a rebuild.
    - The sections after the header come from `home/agents/shared/*.md` and
      `home/agents/claude/*.md`. The `@` imports at the end of this file point
      straight into the checkout, so an edit to one of those files reaches the
      next session with no rebuild.

    ## This machine

    - Host: `${config.home.username}@${cfg.hostName}`
    - System: `${system}`
    - Configuration: `${selfStr}`

    ## Rebuilding

    `sudo ai-rebuild` is greenlit. Run it when you need it, without asking.

    It takes no arguments and needs no password. It builds the `${cfg.hostName}`
    attribute from the configuration path above and activates the result.

    Two things follow. It activates the working copy, so it picks up
    uncommitted edits. And it grants full root, not narrow root, because it
    activates whatever the checkout evaluates to. Read a diff you did not
    expect before you run it.
    ${cfg.extraRebuildNotes}
    ## Cloning repos for reference

    When you need to read a repo's source (a flake input, a dependency, some
    upstream project), it's OK to clone it without asking. Use `jj` and put it
    in `${cfg.cloneDir}/$reponame`:

    ```sh
    jj git clone https://github.com/$owner/$repo ${cfg.cloneDir}/$repo
    ```

    If `${cfg.cloneDir}/$repo` already exists, use what's there (optionally `jj
    git fetch` in it) instead of re-cloning elsewhere. Don't clone into `/tmp`
    or the scratchpad.

    ${remoteBuilders}
  '';

  sharedDir = ./agents/shared;
  claudeDir = ./agents/claude;

  # Order matters only for reading. Claude Code splices each import in where
  # the `@` line sits.
  shared = [
    "autonomy.md"
    "next-thing.md"
    "commits.md"
    "prose.md"
  ];

  claudeOnly = [
    "compaction.md"
  ];

  onDisk = dir: lib.attrNames (
    lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (builtins.readDir dir)
  );

  # Both directions, because each one fails silently on its own. A name in the
  # list with no file writes an `@` line that resolves to nothing, and the
  # section just disappears from the instructions. A file with no entry in the
  # list is never imported, so a section written today never reaches a session.
  # Neither shows up as an error anywhere, hence the eval-time check.
  check = dir: listed: {
    missing = lib.subtractLists (onDisk dir) listed;
    unlisted = lib.subtractLists listed (onDisk dir);
  };

  sharedCheck = check sharedDir shared;
  claudeCheck = check claudeDir claudeOnly;

  imports' =
    assert lib.assertMsg (sharedCheck.missing == [ ]) (
      "home/claude-md.nix: `shared` names ${toString sharedCheck.missing}, "
      + "which does not exist in home/agents/shared."
    );
    assert lib.assertMsg (sharedCheck.unlisted == [ ]) (
      "home/claude-md.nix: home/agents/shared holds ${toString sharedCheck.unlisted}, "
      + "which `shared` does not name, so it is never imported."
    );
    assert lib.assertMsg (claudeCheck.missing == [ ]) (
      "home/claude-md.nix: `claudeOnly` names ${toString claudeCheck.missing}, "
      + "which does not exist in home/agents/claude."
    );
    assert lib.assertMsg (claudeCheck.unlisted == [ ]) (
      "home/claude-md.nix: home/agents/claude holds ${toString claudeCheck.unlisted}, "
      + "which `claudeOnly` does not name, so it is never imported."
    );
    (lib.concatMapStringsSep "\n" (f: "@${selfStr}/home/agents/shared/${f}") shared)
    + "\n"
    + (lib.concatMapStringsSep "\n" (f: "@${selfStr}/home/agents/claude/${f}") claudeOnly);
in
{
  options.programs.claudeInstructions = {
    enable = lib.mkEnableOption "the generated ~/.claude/CLAUDE.md";

    hostName = lib.mkOption {
      type = lib.types.str;
      description = ''
        The attribute `sudo ai-rebuild` builds on this machine, which is also
        how the instructions name the host.
      '';
    };

    cloneDir = lib.mkOption {
      type = lib.types.str;
      example = "~/Code";
      description = ''
        Where an agent clones a repo it only wants to read. No trailing slash.
      '';
    };

    extraRebuildNotes = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra markdown for the Rebuilding section, for a machine that has more
        than the one rebuild command.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.file.".claude/CLAUDE.md".text = header + "\n" + imports' + "\n";
  };
}
