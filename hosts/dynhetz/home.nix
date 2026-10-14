{
  config,
  inputs,
  lib,
  osConfig,
  pkgs,
  ...
}:
{
  imports = [
    ../../home
    # The message hub's MCP server and CLI. The daemon runs as the user
    # service below; ../../home/claude/skills/ocahub documents the tools.
    ../../home/ocahub-mcp.nix
    "${inputs.aid}/nix/home-manager.nix"
    ./aid-web.nix
  ];

  # The AI daemon, as a user service. Its agents would otherwise inherit
  # WAPTY_ID from whichever wrapped session a restart runs under; see
  # ../../home/wrapty.nix.
  services.aid = {
    enable = true;
    package = pkgs.aid;
    # aid's claude-tty sessions run in a pymux server aid starts with this.
    pymuxPackage = (import inputs.pyterm { inherit pkgs; }).pymux;
    extraPackages = [ pkgs.claude-agent-acp ];
    environment.WRAPTY_DISABLE = "1";
    # Model provider API keys (../../secrets/secrets.nix, aid-env.age). `%t`
    # and not the secret's `path`: that holds a literal ${XDG_RUNTIME_DIR},
    # which EnvironmentFile does not expand.
    environmentFile = "%t/agenix/aid-env";
    # Where aid finds pydantic-ai agents: modules defining aid.PydanticAgent
    # subclasses. Your own go in the first; the second is aid's examples, at the
    # pinned revision. Edits need no restart, only a new listing.
    agentsPath = [
      "${config.xdg.configHome}/aid/agents"
      "${inputs.aid}/examples"
    ];
    # Sessions may name their own worker command; a command runs as the daemon
    # with the session's worker credentials. Needs the aid input at 8913f929+.
    allowWorkerCommand = true;
  };
  # Telegram runs hosted in the daemon now (Lillecarl/aid in-process plugins):
  # the token and chat allowlist live in aid-env.age beside DEEPSEEK_API_KEY,
  # which the daemon already sources as its environmentFile.
  age.secrets.aid-env.file = ../../secrets/aid-env.age;
  systemd.user.services.aid.Unit = {
    Requires = [ "agenix.service" ];
    After = [ "agenix.service" ];
  };

  # The cross-agent message hub: a ZeroMQ broker every agent session
  # registers with. Idle it is one epoll-waiting process; Restart=always
  # matters because agents reconnect silently but the in-memory registry
  # does not survive a crash, so a promptly restarted hub is the difference
  # between one missed message and many. Sockets live in
  # $XDG_RUNTIME_DIR/ocahub, the mailbox in ~/.local/state/ocahub.
  systemd.user.services.ocahub = {
    Unit.Description = "ocahub: cross-agent message hub for OpenCode";
    Service = {
      # getExe resolves mainProgram, which is the client `ocac` -- the
      # daemon must be named explicitly.
      ExecStart = "${lib.getExe' pkgs.ocahub "ocahubd"}";
      Restart = "always";
      RestartSec = "2";
    };
    Install.WantedBy = [ "default.target" ];
  };

  # There is a NixOS underneath this one, so take its stateVersion rather than
  # keep a second copy that can drift from it.
  home.stateVersion = osConfig.system.stateVersion;

  # The `t3` CLI beside the service below: `t3 pair` mints pairing tokens
  # against the running server, `t3 --help` lists the rest. Scoped to this
  # host rather than shared in ../../home/packages.nix -- the service it
  # talks to lives here.
  home.packages = [ pkgs.t3code ];

  # T3 Code, headless: the server workspace from pkgs/t3code (`t3 serve`,
  # no browser, pairing URL in the logs). Loopback only -- reach it over
  # `ssh -L 18789:localhost:18789 dynhetz` and open the pairing URL from
  # `journalctl --user -u t3code -f` on first start. (linger is already on
  # for this user, so the user manager -- and this service -- starts at boot
  # with nobody logged in.)
  systemd.user.services.t3code = {
    Unit.Description = "T3 Code server (headless, built from source)";
    Service = {
      ExecStart = "${lib.getExe pkgs.t3code} serve --port 18789 --host 127.0.0.1 --no-browser";
      Restart = "always";
      RestartSec = "2";
    };
    Install.WantedBy = [ "default.target" ];
  };

  # Spotify playback and control in a terminal. Scoped to this host rather
  # than shared: it plays through this machine's system-wide PipeWire.
  programs.spotify-player = {
    enable = true;
    settings = {
      # From an app at https://developer.spotify.com/dashboard (redirect URI
      # http://127.0.0.1:8989/login). Uncomment and rebuild once it exists;
      # without it `spotify_player` refuses to start.
      # client_id = "...";
      # No `theme` here: catppuccin (../../home/default.nix) already themes
      # this program, and a second definition conflicts with it.
      device = {
        name = "dynhetz";
      };
    };
  };

  # See ../../home/wrapty.nix -- puts wrapty on PATH so ../../home/fish/
  # functions/claude.fish routes `claude` through it, and so the Claude Code
  # plugin manifest under ../../home/claude/skills/wrapty can name its
  # binaries bare.
  programs.wrapty.enable = true;

  # See ../../home/agent-machine.nix -- the machine section every harness
  # reads. Only the values that differ per machine live here.
  programs.agentMachine = {
    enable = true;
    hostName = "dynhetz";
    cloneDir = "~/Code";
  };

  # See ../../home/claude-md.nix -- generates ~/.claude/CLAUDE.md. Shared
  # prose, read live out of the checkout through `@` imports.
  programs.claudeInstructions.enable = true;

  # See ../../home/codex-md.nix -- generates ~/.codex/AGENTS.md. Shared prose
  # only, inlined at build time; Codex has no import mechanism.
  programs.codexInstructions.enable = true;
}
