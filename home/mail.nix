{
  config,
  lib,
  platform,
  ...
}:
{
  # Mail on Migadu: imap.migadu.com:993 and smtp.migadu.com:465 for every
  # domain they host. One mailbox, carl@postspace.net: postspace.net is
  # linked to lillecarl.com, both domains carry a catch-all into that
  # mailbox, and every address under either domain is a sending identity.
  # The password holds a placeholder until filled:
  #
  #   cd secrets && agenix -e migadu-pass.age -i identity.age
  age.secrets.migadu-pass.file = ../secrets/migadu-pass.age;

  accounts.email.maildirBasePath = "mail";

  accounts.email.accounts.postspace = {
    primary = true;
    # The mailbox itself, which is also the IMAP and SMTP login.
    address = "carl@postspace.net";
    realName = "Carl";
    userName = "carl@postspace.net";
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
      # makes neomutt pass -f, so the envelope follows whatever identity
      # the From header carries and Migadu permits all of them.
      sendMailCommand = "msmtp";
      extraConfig = ''
        set use_envelope_from = yes
        # Catch-all on both domains: a reply should come from the address
        # the mail was sent to. alternates whitelists what can be a From,
        # reverse_name picks the matching one; new mail goes out as the
        # mailbox address unless the From is edited to another alias.
        set reverse_name = yes
        alternates ".*@postspace\\.net|.*@lillecarl\\.com"
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
