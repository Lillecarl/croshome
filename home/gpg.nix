{
  lib,
  pkgs,
  platform,
  ...
}:
let
  # ../secrets/pgp-keys.nix, written by ../secrets/pgp-create. Both entries are
  # null until that script has run once, ever.
  keys = import ../secrets/pgp-keys.nix;
in
{
  # OpenPGP on every machine that imports this directory.
  #
  # Two identities, one key each: the work address and the personal one. That
  # is the same split ./vcs.nix already makes for the commit author, and
  # ./vcs.nix reads the fingerprints above to sign with the matching key.
  #
  # This module only makes gpg and its agent exist and behave. It decrypts
  # nothing. The secret keys live in ../secrets as age files, and
  # ../secrets/pgp-import puts one into GnuPG. That is a one-time act per
  # machine, so it is a script you run and not an activation step -- see
  # ../secrets/README.md for why nothing here needs the agenix home module.
  programs.gpg = {
    enable = true;

    settings = {
      # The work key, to match the work commit address that ./vcs.nix makes
      # the default. `gpg --sign` with no `-u` then does the expected thing.
      default-key = lib.mkIf (keys.work != null) keys.work;

      # keys.openpgp.org, so `gpg --recv-keys` and `--send-keys` reach
      # somewhere that verifies the address before it serves a user ID. The
      # old SKS pool served anything anyone uploaded, which is how keys got
      # poisoned with thousands of bogus signatures.
      keyserver = "hkps://keys.openpgp.org";
    };
  };

  services.gpg-agent = {
    enable = true;

    # pinentry-curses on Linux, and that is a deliberate choice over the GTK
    # one. Every place this configuration asks for a passphrase is a terminal
    # -- foot, tmux, ttyd, or ssh into hetztop -- and the curses prompt is the
    # only variant that works in all four. A graphical pinentry fails over ssh,
    # which is the case that matters most here.
    #
    # The cost is real and worth naming: a program with no controlling
    # terminal, such as a GUI git client, gets no prompt at all. Nothing in
    # this configuration is such a program today.
    #
    # macOS gets pinentry_mac, which draws a native panel and can put the
    # passphrase in the Keychain. There is no curses equivalent worth using
    # there, and every Mac session has a window server.
    pinentry.package = if platform.isDarwin then pkgs.pinentry_mac else pkgs.pinentry-curses;

    # Eight hours since the last use, and one day since it was typed. So a
    # working day costs one passphrase, and a machine left alone overnight asks
    # again. The keys carry their own passphrase precisely so this cache can be
    # generous: see ../secrets/README.md.
    defaultCacheTtl = 28800;
    maxCacheTtl = 86400;

    # ssh keys stay with ssh. gpg-agent can serve them, but ./default.nix
    # already configures OpenSSH and nothing here needs an authentication
    # subkey, so turning this on would only move a working thing.
    enableSshSupport = false;
  };
}
