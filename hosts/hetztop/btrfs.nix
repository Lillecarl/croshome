{ pkgs, ... }:
let
  # sudo matches the command as it resolves it on PATH, and does not follow the
  # symlink, so this is the path `sudo btrfs` actually presents. It is also the
  # one that survives an update: a `${pkgs.btrfs-progs}/bin/btrfs` store path
  # would stop matching the moment btrfs-progs was rebuilt.
  btrfs = "/run/current-system/sw/bin/btrfs";

  # Inspection, snapshots and balancing, run without a password prompt so an
  # agent can look at the filesystem and rebalance it unattended.
  #
  # What is deliberately *not* here: `subvolume delete`, `device add/remove`,
  # `filesystem resize`, `scrub start`. Those still ask for a password, which is
  # the only thing standing between a wrong argument and data loss on a root
  # filesystem that is also /nix and /home.
  #
  # A `*` in sudoers matches whitespace as well, so one trailing `*` covers the
  # whole rest of the command line however many arguments it is. It does not
  # match the *absence* of an argument, which is why the two subcommands that
  # are useful with no path at all are listed a second time without it.
  allowed = [
    # Read-only.
    "subvolume list *"
    "subvolume show *"
    "subvolume get-default *"
    "filesystem show"
    "filesystem show *"
    "filesystem df *"
    "filesystem usage *"
    "scrub status *"
    "qgroup show *"
    "device stats *"
    "device usage *"
    "property get *"
    # Writes, allowed on purpose.
    "subvolume snapshot *"
    # Covers `balance start`, `status`, `pause`, `resume` and `cancel`, and the
    # bare `btrfs balance <path>` spelling of start.
    "balance *"
  ];
in
{
  # This machine builds Nix packages more or less constantly, and a store of
  # millions of small files turns that into extent and csum churn. The result is
  # that data chunks end up allocated but only part full, and once the device is
  # fully allocated, metadata -- which is the part that grows under that churn --
  # cannot get another chunk. That state reports as ENOSPC with plenty of free
  # space in df, and it is also the state in which balance itself starts failing
  # with -28, because relocation has nowhere to relocate to (this happened on
  # 2026-08-05 and 2026-08-10; on 2026-08-15 the device was 100% allocated with
  # metadata at 92%, and one -dusage=20 pass took 13 seconds and gave back 7GiB).
  #
  # So: reclaim the mostly-empty data chunks every week, before allocation
  # reaches the point where the fix no longer runs. Data only. A metadata
  # balance on a nearly-full metadata allocation is the one that gets stuck.
  systemd.services.btrfs-balance = {
    description = "btrfs balance of / (reclaim mostly-empty data chunks)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.btrfs-progs}/bin/btrfs balance start -dusage=20 /";
      # Losing to anything that actually wants the disk is fine; this is
      # housekeeping and it has all week.
      Nice = 19;
      IOSchedulingClass = "idle";
    };
    # A failure here is worth seeing rather than swallowing: `btrfs balance`
    # exits non-zero on ENOSPC, and that is the early warning that allocation
    # got away from us again.
  };

  systemd.timers.btrfs-balance = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      # The machine is not always up, and a missed week is exactly when
      # allocation has been left alone the longest.
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  security.sudo.extraRules = [
    {
      users = [ "lillecarl" ];
      commands = map (args: {
        command = "${btrfs} ${args}";
        options = [ "NOPASSWD" ];
      }) allowed;
    }
  ];
}
