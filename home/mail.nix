{
  config,
  lib,
  platform,
  ...
}:
{
  # Mail on Migadu: imap.migadu.com:993 and smtp.migadu.com:465 for every
  # domain they host, so the two accounts differ only in the address. The
  # mailbox passwords are home-agenix secrets, decrypted at login into
  # $XDG_RUNTIME_DIR/agenix (Darwin equivalent on the Mac). They hold
  # placeholders until filled:
  #
  #   cd secrets && agenix -e migadu-postspace-pass.age -i identity.age
  #   cd secrets && agenix -e migadu-lillecarl-pass.age -i identity.age
  age.secrets.migadu-postspace.file = ../secrets/migadu-postspace-pass.age;
  age.secrets.migadu-lillecarl.file = ../secrets/migadu-lillecarl-pass.age;

  accounts.email.maildirBasePath = "mail";

  accounts.email.accounts.postspace = {
    address = "carl@postspace.net";
    realName = "Carl";
    userName = "carl@postspace.net";
    passwordCommand = "cat ${config.age.secrets.migadu-postspace.path}";
    imap = {
      host = "imap.migadu.com";
      port = 993;
    };
    smtp = {
      host = "smtp.migadu.com";
      port = 465;
    };
    mbsync = {
      enable = true;
      create = "both";
    };
    msmtp.enable = true;
    neomutt.enable = true;
  };

  accounts.email.accounts.lillecarl = {
    primary = true;
    address = "lillecarl@lillecarl.com";
    realName = "lillecarl";
    userName = "lillecarl@lillecarl.com";
    passwordCommand = "cat ${config.age.secrets.migadu-lillecarl.path}";
    imap = {
      host = "imap.migadu.com";
      port = 993;
    };
    smtp = {
      host = "smtp.migadu.com";
      port = 465;
    };
    mbsync = {
      enable = true;
      create = "both";
    };
    msmtp.enable = true;
    neomutt.enable = true;
  };

  programs.mbsync.enable = true;
  programs.msmtp.enable = true;
  programs.neomutt.enable = true;

  # The sync timer is a systemd user unit, so darwin gets mbsync on the PATH
  # but no timer and runs it by hand until a launchd agent exists for it.
  services.mbsync = lib.mkIf platform.isLinux {
    enable = true;
    frequency = "*:0/5";
  };
}
