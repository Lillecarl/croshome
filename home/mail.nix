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
      # 587/STARTTLS, not 465: nothing on this network reaches Migadu's
      # 465 -- every address in their pool times out, while 587 connects
      # (Hetzner filters outbound mail ports; 587 is the one that lives).
      port = 587;
      tls.useStartTls = true;
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

  # Work mail on Google Workspace. Google accepts no account password over
  # IMAP or SMTP; this is an app password, which needs 2-Step Verification.
  #
  #   cd secrets && agenix -e dynamist-mail-pass.age
  age.secrets.dynamist-mail-pass.file = ../secrets/dynamist-mail-pass.age;

  accounts.email.accounts.dynamist = {
    flavor = "gmail.com";
    address = "carl.andersson@dynamist.se";
    realName = "Carl Andersson";
    # Google shows app passwords in groups of four; the spaces are not part of it.
    passwordCommand = "tr -d ' ' < ${config.age.secrets.dynamist-mail-pass.path}";
    # 587, not 465: Hetzner drops outbound 465 to Gmail as it does to Migadu.
    smtp.tls.useStartTls = true;
    folders = {
      inbox = "INBOX";
      drafts = "[Gmail]/Drafts";
      trash = "[Gmail]/Trash";
      # Gmail files everything sent over SMTP in Sent Mail by itself, so
      # neomutt keeps no copy of its own.
      sent = null;
    };
    mbsync = {
      enable = true;
      # Only local creation: a folder made remotely becomes a Gmail label.
      create = "maildir";
      # All Mail, Important and Starred are label views over the same
      # messages and would store every mail a second time.
      patterns = [
        "*"
        "![Gmail]/All Mail"
        "![Gmail]/Important"
        "![Gmail]/Starred"
      ];
    };
    msmtp.enable = true;
    neomutt = {
      enable = true;
      sendMailCommand = "msmtp --account=dynamist";
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
