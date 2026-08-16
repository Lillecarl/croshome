{ config, pkgs, ... }:
let
  logFile = "${config.users.users.lillecarl.home}/Library/Logs/cocoa-way.log";

  # The working copy next door, not a fetched revision: this is where the
  # packaging is being developed.
  cocoa-way = import ../../../cocoa-way { inherit pkgs; };
in
{
  imports = [ ../../../cocoa-way/nix/darwin-module.nix ];

  # The module already installs Cocoa-Way itself. Waypipe is what you invoke by
  # hand (`waypipe ssh user@host firefox`), so it belongs in the shell too, not
  # only on the agent's PATH.
  environment.systemPackages = [ cocoa-way.waypipe-darwin ];

  # The module defaults to pkgs.cocoa-way, which only exists through the
  # overlay; nixpkgs.pkgs is already pinned here, so pass the packages in.
  services.cocoa-way = {
    enable = true;
    package = cocoa-way.cocoa-way;
    # Transported applications need a Mac-side waypipe on the agent's PATH.
    extraPackages = [ cocoa-way.waypipe-darwin ];

    # Individual Linux applications, each in its own native window, rather than
    # a Linux desktop inside one window.
    presentation = "rootless";
    # Keep the Dock tile. An LSUIElement application is absent from the Dock
    # and from Cmd-Tab, which also strands the windows its clients open: once
    # another application is focused there is no way back to them except
    # minimising whatever is on top. Rootless already keeps the compositor
    # itself off the screen, so the only cost is an idle tile.
    showInDock = true;

    # With no window and no menu bar this is the only feedback channel left,
    # and the startup banner is what names the Wayland socket that clients
    # connect to -- the control API reports only the control socket.
    logFile = logFile;
    errorLogFile = logFile;
  };
}
