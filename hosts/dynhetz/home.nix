{ lib, osConfig, pkgs, ... }:
{
  imports = [ ../../home ];

  # The vendored xonsh bundle, built by the overlay entry of the same name
  # (../../pkgs/default.nix). Installed but deliberately not made anyone's
  # shell: it is still rounds away from ready, and fish stays users.users'
  # shells.lillecarl.shell until it is. Launch it as `anyxonsh` to try it.
  home.packages = [
    pkgs.anyxonsh

    # The `ocac` client, on PATH for agents. The daemon runs as the user
    # service below; see ../../home/agents/shared/comms.md for the commands.
    pkgs.ocahub
  ];

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

  # See ../../home/wrapty.nix -- puts wrapty on PATH so ../../home/fish/
  # functions/claude.fish routes `claude` through it, and so the Claude Code
  # plugin manifest under ../../home/claude/skills/wrapty can name its
  # binaries bare.
  programs.wrapty.enable = true;

  # See ../../home/claude-md.nix -- generates ~/.claude/CLAUDE.md. Only the
  # values that differ per machine live here; the prose is shared.
  programs.claudeInstructions = {
    enable = true;
    hostName = "dynhetz";
    cloneDir = "~/Code";
  };
}
