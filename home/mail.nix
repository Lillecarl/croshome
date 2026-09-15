{
  config,
  lib,
  platform,
  ...
}:
{
  # Mail on Migadu: imap.migadu.com:993 and smtp.migadu.com:465 for every
  # domain they host. One mailbox: postspace.net is linked to lillecarl.com,
  # so both addresses are sending identities of the same account and share
  # one password. It holds a placeholder until filled:
  #
  #   cd secrets && agenix -e migadu-pass.age -i identity.age
  age.secrets.migadu-pass.file = ../secrets/migadu-pass.age;

  accounts.email.maildirBasePath = "mail";

  accounts.email.accounts.lillecarl = {
    primary = true;
    address = "lillecarl@lillecarl.com";
    realName = "lillecarl";
    userName = "lillecarl@lillecarl.com";
    passwordCommand = "cat ${config.age.secrets.migadu-pass.path}";
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
    neomutt = {
      enable = true;
      # Through msmtp rather than neomutt's own SMTP, so scripts and mutt
      # share one account, one trust store and one queue. use_envelope_from
      # makes neomutt pass -f, and the command line wins over the account's
      # pinned from -- otherwise msmtp would send every message as the
      # primary address.
      sendMailCommand = "msmtp";
      extraConfig = ''
        set use_envelope_from = yes
        send-hook '~t postspace\.net' 'set from = "carl@postspace.net"; set realname = "Carl"'
        send-hook '! ~t postspace\.net' 'set from = "lillecarl@lillecarl.com"; set realname = "lillecarl"'
      '';
    };
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
