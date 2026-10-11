{ pkgs, lib, ... }:
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

  # Headroom guard: balance on threshold, not on calendar. Checks
  # `btrfs filesystem usage` every 15 minutes -- one ioctl and two awk
  # runs, milliseconds -- and starts a data-only balance when metadata is
  # over 80% used or unallocated space is under 5G. The balance itself is
  # the only expensive part and it runs only on breach, at idle priority:
  # recent passes took seconds (13s for 7GiB on 2026-08-15, 41 chunks on
  # 2026-10-08). Fail-closed: unparseable output or still-low headroom
  # after a balance exits non-zero, so the timer failure is the alert. An
  # already-running balance is left alone, and a balance that frees
  # nothing cools down for 6h rather than churning on a genuinely full
  # disk. Same housekeeping priority as the weekly balance below.
  ensure-headroom = pkgs.writeShellApplication {
    name = "btrfs-ensure-headroom";
    runtimeInputs = [
      pkgs.btrfs-progs
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      usage=$(btrfs filesystem usage -b /)
      unallocated=$(printf '%s\n' "$usage" | awk '/Device unallocated:/ { print $3 }')
      metapct=$(printf '%s\n' "$usage" | awk '/^Metadata,/ { if (match($0, /\(([0-9.]+)%\)/, m)) print m[1] }')

      if [ -z "$unallocated" ] || [ -z "$metapct" ]; then
        echo "btrfs-ensure-headroom: could not parse filesystem usage" >&2
        printf '%s\n' "$usage" >&2
        exit 1
      fi

      echo "metadata ''${metapct}% used, unallocated ''${unallocated} bytes"

      if [ "''${metapct%%.*}" -lt 80 ] && [ "$unallocated" -ge 5368709120 ]; then
        echo "headroom fine, no balance needed"
        exit 0
      fi

      if btrfs balance status / | grep -q "is running"; then
        echo "a balance is already running, leaving it to it"
        exit 0
      fi

      # A balance that frees nothing means genuinely full, not fragmented.
      # Do not churn: at most one balance per cooldown window, but keep
      # failing so the timer stays red until someone looks.
      state_dir="''${RUNTIME_DIRECTORY:-/tmp}"
      now=$(date +%s)
      last=$(cat "$state_dir/last-balance" 2>/dev/null || echo 0)
      if [ $(( now - last )) -lt 21600 ]; then
        echo "headroom low and balanced recently, needs attention" >&2
        exit 1
      fi

      echo "headroom low, starting data balance"
      btrfs balance start -dusage=20 /
      date +%s > "$state_dir/last-balance"

      usage=$(btrfs filesystem usage -b /)
      unallocated=$(printf '%s\n' "$usage" | awk '/Device unallocated:/ { print $3 }')
      metapct=$(printf '%s\n' "$usage" | awk '/^Metadata,/ { if (match($0, /\(([0-9.]+)%\)/, m)) print m[1] }')
      echo "after balance: metadata ''${metapct}% used, unallocated ''${unallocated} bytes"

      if [ "''${metapct%%.*}" -ge 80 ] || [ "$unallocated" -lt 5368709120 ]; then
        echo "headroom still low after balance, needs attention" >&2
        exit 1
      fi
    '';
  };
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
  # 2026-10-08: weekly lost the race. Metadata hit 97.5% with 1MiB
  # unallocated, `nix-collect-garbage -d` stalled on a generation, and df
  # still showed 71G free. Clearing /tmp cruft and vacuuming the journal
  # moved metadata to 92%; one manual -dusage=20 pass then freed 34GiB of
  # unallocated and metadata grew 24G -> 27G on its own. So weekly is now
  # "at latest": btrfs-ensure-headroom above balances on threshold.
  #
  # So: reclaim the mostly-empty data chunks every week, before allocation
  # reaches the point where the fix no longer runs. Data only. A metadata
  # balance on a nearly-full metadata allocation is the one that gets stuck.
  systemd.services.btrfs-balance = {
    description = "btrfs balance of / (reclaim mostly-empty data chunks)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe pkgs.btrfs-progs} balance start -dusage=20 /";
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

  systemd.services.btrfs-ensure-headroom = {
    description = "btrfs headroom check of / (balance on threshold, not calendar)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe ensure-headroom;
      Nice = 19;
      IOSchedulingClass = "idle";
      RuntimeDirectory = "btrfs-ensure-headroom";
    };
    # Same reasoning as btrfs-balance: a non-zero exit here is the alert.
  };

  systemd.timers.btrfs-ensure-headroom = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = true;
      RandomizedDelaySec = "2min";
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
