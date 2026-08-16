{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.aerospace;

  workspaces = map toString (lib.range 1 9);

  # alt-N focuses a workspace, alt-shift-N throws the focused window at it.
  workspaceBindings = lib.listToAttrs (
    lib.concatMap (ws: [
      (lib.nameValuePair "alt-${ws}" "workspace ${ws}")
      (lib.nameValuePair "alt-shift-${ws}" "move-node-to-workspace ${ws}")
    ]) workspaces
  );

  # The whole file, written here rather than through services.aerospace.settings.
  # That option's submodule has a default for every key it knows and no way to
  # unset one, and it is shaped for config-version 1, so anything AeroSpace has
  # since renamed or dropped gets emitted regardless -- which is how
  # `accordion-padding` kept reappearing. Owning the attrset means only what is
  # written below reaches the config, and the module is used purely for the
  # package and the launchd agent.
  settings = {
    # 1 is what nix-darwin's module targets; 2 is current, and going there is
    # what silences the migration warning on every start.
    config-version = 2;

    # config-version 2 stopped inferring these from the keybindings.
    persistent-workspaces = workspaces;

    gaps = {
      # Wide enough to fit both neighbours' 6pt JankyBorders with a gap left
      # between them; see ./borders.nix.
      inner.horizontal = 14;
      inner.vertical = 14;
      outer = {
        left = 8;
        right = 8;
        top = 8;
        bottom = 8;
      };
    };

    # A workspace holding one or two windows does not need the tree
    # normalisation that keeps deeply nested splits tidy.
    enable-normalization-flatten-containers = true;
    enable-normalization-opposite-orientation-for-nested-containers = true;
    default-root-container-layout = "tiles";
    default-root-container-orientation = "auto";

    # Accordion padding is deliberately absent. 0.21.3-Beta warns that
    # `accordion-padding` is renamed to `accordion.padding`, but rejects the
    # replacement with "accordion: Unknown top-level key" -- the deprecation
    # landed ahead of the option. Omitting it entirely leaves the built-in
    # default of 30 and is the only spelling this version accepts.

    # Workspaces are a single pool shared by every monitor, and each monitor
    # shows exactly one of them. Without a forced assignment a workspace
    # simply appears on whichever monitor is focused when you switch to it,
    # which is what you want for a laptop that is sometimes docked. To pin
    # some anyway:
    #
    #   workspace-to-monitor-force-assignment = {
    #     "1" = "main";
    #     "9" = "secondary";
    #   };

    # Keep the pointer with the focus, otherwise hover and scroll stay on the
    # monitor you just left.
    on-focused-monitor-changed = [ "move-mouse monitor-lazy-center" ];

    mode.main.binding = workspaceBindings // {
      # Within a workspace.
      alt-h = "focus left";
      alt-j = "focus down";
      alt-k = "focus up";
      alt-l = "focus right";
      alt-shift-h = "move left";
      alt-shift-j = "move down";
      alt-shift-k = "move up";
      alt-shift-l = "move right";

      # Between workspaces. AeroSpace's own default for alt-tab, and the
      # closest thing to the reflex it replaces.
      alt-tab = "workspace-back-and-forth";

      # Between monitors: focus, then drag the window along, then hand the
      # whole workspace over.
      alt-ctrl-h = "focus-monitor --wrap-around left";
      alt-ctrl-l = "focus-monitor --wrap-around right";
      alt-ctrl-shift-h = "move-node-to-monitor --wrap-around --focus-follows-window left";
      alt-ctrl-shift-l = "move-node-to-monitor --wrap-around --focus-follows-window right";
      alt-ctrl-shift-m = "move-workspace-to-monitor --wrap-around next";

      # Accordion is the stacked layout: every window in the container gets
      # the full area minus the accordion padding per neighbour, so they sit on
      # top of each other and alt-h/l steps through them. Each command lists
      # several target layouts, which makes it a toggle: pressing it again
      # flips the orientation. Add --root to apply to the whole workspace
      # rather than just the focused window's container.
      alt-s = "layout accordion horizontal vertical";
      alt-t = "layout tiles horizontal vertical";

      # Escape hatches for windows that refuse to tile.
      alt-f = "layout floating tiling";
      alt-shift-f = "fullscreen";
    };
  };

  configFile = (pkgs.formats.toml { }).generate "aerospace.toml" settings;
in
{
  launchd.user.agents.aerospace.command =
    lib.mkForce "${cfg.package}/Applications/AeroSpace.app/Contents/MacOS/AeroSpace --config-path ${configFile}";

  services.aerospace.enable = true;
}
