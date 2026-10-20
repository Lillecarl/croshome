# The machine section every agent harness reads: which host this is, how to
# rebuild it, where to clone a repo for reading, and which nix-community
# builder matches this system.
#
# It lives here rather than in ./claude-md.nix because none of it is
# Claude-specific and every harness needs it. opencode in particular never
# sees ~/.claude/CLAUDE.md: it picks the FIRST existing file out of
# ~/.config/opencode/AGENTS.md then ~/.claude/CLAUDE.md and stops there, so
# the AGENTS.md this configuration writes shadows CLAUDE.md completely.
#
# Two outputs, because the harnesses take their instructions differently:
#
# - `text` is the markdown, for a module that inlines it (./claude-md.nix,
#   ./codex-md.nix).
# - `relPath` names a copy written to the home directory, for opencode's
#   `instructions` list. Not a store path: opencode resolves an absolute
#   entry by globbing its basename inside its dirname, and a store path would
#   point that glob at /nix/store.
{
  config,
  lib,
  pkgs,
  selfStr,
  ...
}:
let
  cfg = config.programs.agentMachine;

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

  builderLine = b: "lillecarl@${b.host} ${system} - 12 1 ${b.features}";

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

  text = ''
    ## This machine

    - Host: `${config.home.username}@${cfg.hostName}`
    - System: `${system}`
    - Configuration: `${selfStr}`

    ## Rebuilding

    `ai-rebuild` is greenlit. Run it when you need it, without asking. No
    sudo in front of it.

    It takes no arguments and needs no password. It builds the `${cfg.hostName}`
    attribute from the configuration path above as your own user, sharing your
    fetcher cache, and elevates once at the end for the switch.

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

    **If nixpkgs packages it, don't clone it at all.** `nix build --file
    /etc/nixpkgs $package.src --no-link --print-out-paths` gives the exact
    revision that built the binary here, patches applied. A clone gives you
    whatever `main` says today, which is a different question.

    ${remoteBuilders}
  '';
in
{
  options.programs.agentMachine = {
    enable = lib.mkEnableOption "the shared machine section every agent harness reads";

    hostName = lib.mkOption {
      type = lib.types.str;
      description = ''
        The attribute `ai-rebuild` builds on this machine, which is also
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

    text = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "The generated markdown, for a harness that inlines it.";
    };

    relPath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = ''
        Where the same markdown is written, relative to the home directory,
        for a harness that takes a list of files.
      '';
    };
  };

  config = {
    # Outside the mkIf: a readOnly option with no default is an eval error for
    # every module that reads it, so a disabled machine section must still
    # answer with an empty string rather than with nothing.
    programs.agentMachine.text = lib.optionalString cfg.enable text;
    programs.agentMachine.relPath = ".config/agent-machine.md";

    home.file = lib.mkIf cfg.enable {
      ${cfg.relPath}.text = text;
    };
  };
}
