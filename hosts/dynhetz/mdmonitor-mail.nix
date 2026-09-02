# mdmonitor.service (from boot.swraid, enabled implicitly by ../disko.nix's
# mdadm RAID1) refuses to even start without a MAILADDR or PROGRAM set --
# "Neither MAILADDR nor PROGRAM has been set. This will cause the mdmon
# service to crash." With neither, `mdadm --monitor --scan` exits
# immediately instead of watching the array at all, so a real disk failure
# would go unnoticed until someone happened to check by hand.
#
# MAILADDR alone silences that and gets the monitor actually running, but
# mdadm sends its alert by shelling out to `sendmail` -- nothing on a
# NixOS system provides that by default, so without a real MTA behind it
# the alert would still silently fail to send on an actual event. OpenSMTPD
# here is local-delivery only: it listens on loopback, not eth0, and
# doesn't relay anywhere -- there's no reason for this box to run a
# real internet-facing mail server just so mdadm has something to mail.
{
  services.opensmtpd = {
    enable = true;
    # Installs the setuid `sendmail` wrapper mdadm (and anything else that
    # shells out to it, e.g. cron) actually calls.
    setSendmail = true;
    serverConfiguration = ''
      listen on lo

      # `mbox` (a shared /var/mail spool) was the first attempt, and a
      # dead end on the real machine: it shells out to opensmtpd-portable's
      # bundled lockspool/mail.local, both OpenBSD tools that assume
      # they're installed setuid-root. nixpkgs doesn't build them that
      # way, and /nix/store is nosuid regardless, so even a same-user
      # lock attempt failed outright ("you must be root to lock someone
      # else's spool") -- fixable only by patching the opensmtpd package
      # itself. maildir is opensmtpd's own native delivery, no external
      # helper and no shared-spool permissions to get right: it just
      # writes into the already-uid-switched recipient's own home
      # directory.
      action "local_mail" maildir "~/Maildir"
      match from local for local action "local_mail"
    '';
  };

  boot.swraid.mdadmConf = "MAILADDR lillecarl";
}
