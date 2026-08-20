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
  haveKeys = keys.work != null && keys.personal != null;

  # One prompt for both keys. gpg-agent caches per subkey rather than per
  # passphrase, so unlocking the work key leaves the personal one locked and
  # the next commit in this repository still stops to ask. pinentry can only
  # be asked about one subkey at a time, so the script reads the passphrase
  # itself and presets every subkey of both keys.
  #
  # `gpg-preset-passphrase` is not on the PATH: gnupg keeps it in libexec,
  # because it is a tool for a program rather than for a person. Named by
  # store path for that reason.
  pgp-unlock = pkgs.writeShellApplication {
    name = "pgp-unlock";
    runtimeInputs = [ pkgs.gnupg ];
    text = ''
      WORK_FPR=${toString keys.work}
      PERSONAL_FPR=${toString keys.personal}
      PRESET_BIN=${pkgs.gnupg}/libexec/gpg-preset-passphrase
    ''
    + builtins.readFile ./pgp-unlock.sh;
  };
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

    # 400 days, both of them, which is "until the agent stops" in practice.
    #
    # This is not a workstation. Agents run on hetztop around the clock and
    # they commit, so a cache that expires overnight means a signing failure
    # every morning until a person types something. Nobody is there at 04:00.
    #
    # Be exact about what this costs, because it is a real reduction. The
    # passphrase still protects the key in two places that matter: at rest in
    # a public repository, and across a reboot. It no longer protects it
    # against anything running as this user on a live machine -- once
    # `pgp-unlock` has run, anything that can reach the agent socket can sign.
    # That is the trade a server makes to sign unattended, and it is the good
    # end of it: the alternative that actually removes the passphrase leaves
    # the key in plaintext on disk instead, which is worse in every way.
    #
    # The cache lives in the agent's memory and nowhere else, so a reboot, a
    # restart or a `gpgconf --reload gpg-agent` empties it. One `pgp-unlock`
    # per boot is the whole maintenance.
    defaultCacheTtl = 34560000;
    maxCacheTtl = 34560000;

    # How long a pinentry prompt waits for you to type before it gives up.
    # Short on purpose, and the reasoning runs against the obvious one.
    #
    # A long prompt looks kinder and is not. Measured here: a jj command
    # sitting at the prompt holds the repository lock for the whole timeout,
    # and a second jj process in that repository blocks until the first one
    # gives up. So an hour would let one cold-cache command in a forgotten
    # tmux pane stall every agent on this machine for an hour. A minute
    # bounds that, and a cold cache is meant to fail loudly anyway.
    #
    # Nothing is lost by it, because the prompt is not the path a person uses.
    # `pgp-unlock` reads the passphrase with `read -s` in the shell, never
    # through pinentry, so it has no timeout and waits as long as you like.
    # pinentry now appears only when something signs with a cold cache, which
    # is the case that should stop quickly and say so.
    #
    # The number has to be stated. gpg-agent's default of 0 does not mean
    # "wait forever": the manual says a pinentry may then apply its own
    # default, so the real limit would be whatever pinentry-curses picked.
    # It does honour the request -- checked by driving it with `SETTIMEOUT 3`,
    # which returned `ERR Timeout` after three seconds.
    #
    # `allow-preset-passphrase` is what lets `pgp-unlock` fill the cache
    # directly. Without it `gpg-preset-passphrase` is refused. It widens
    # nothing meaningfully: a process running as this user could already ask
    # for the passphrase through pinentry.
    extraConfig = ''
      pinentry-timeout 60
      allow-preset-passphrase
    '';

    # ssh keys stay with ssh. gpg-agent can serve them, but ./default.nix
    # already configures OpenSSH and nothing here needs an authentication
    # subkey, so turning this on would only move a working thing.
    enableSshSupport = false;
  };

  # Only once the keys exist. `pgp-unlock` names both fingerprints, so before
  # ../secrets/pgp-create has run there is nothing for it to unlock.
  home.packages = lib.optional haveKeys pgp-unlock;
}
