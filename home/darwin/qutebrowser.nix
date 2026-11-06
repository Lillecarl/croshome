{ ... }:
{
  # On trial as the main browser. The package comes from our fork, through
  # the overlay. Its cask is disabled: it fails Gatekeeper.
  programs.qutebrowser = {
    enable = true;
    # `:set` writes autoconfig.yml; load it, so a setting tried at runtime
    # survives a restart until it moves here.
    loadAutoconfig = true;
  };
}
