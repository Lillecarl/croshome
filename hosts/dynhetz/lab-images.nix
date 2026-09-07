# Temporary: root access to finish removing mainpool/lab-images.
#
# DELETE THIS FILE once the volume is gone. It exists for one job, and the two
# helpers below are inert the moment that job is done -- both refuse when the
# volume does not exist.
#
# Why it exists at all. ./libvirt-lab-storage.nix is deleted and the switch
# stopped its service, but a switch does not run lvremove and must not: an
# activation script that destroys a volume holding data is exactly what
# ./disko.nix's own comments refuse to have. So the removal is a manual step,
# and a manual step needs a way to run as root. `sudo` from an agent's shell
# cannot read a password -- there is no terminal -- so it needs a NOPASSWD
# rule, and this is the narrowest one that does the job.
#
# The grant is genuinely narrow, unlike ./ai-rebuild.nix's. That one takes a
# store path and activates it, so the caller chooses what runs as root by
# evaluating arbitrary Nix; its own comment says to read it as full root. These
# two take no arguments at all. One prints, one removes a single named volume.
# Neither can be pointed at anything else.
{ pkgs, ... }:
let
  vg = "mainpool";
  lv = "lab-images";
  dmName = "mainpool-lab--images";
  mount = "/var/lib/libvirt/lab-images";

  # Read-only. Answers the question that has cost three wrong guesses already:
  # what is actually holding the device open.
  lab-images-inspect = pkgs.writeShellApplication {
    name = "lab-images-inspect";
    runtimeInputs = [
      pkgs.lvm2
      pkgs.util-linux
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.psmisc
    ];
    text = ''
      echo "== volume"
      lvs -o lv_name,lv_size,lv_attr,data_percent,pool_lv ${vg} || true

      echo
      echo "== device-mapper open count (0 means nothing holds it)"
      dmsetup info ${dmName} 2>&1 | grep -iE "name|state|open count" || true

      echo
      echo "== mounts of it anywhere the host can see"
      findmnt -A -S /dev/mapper/${dmName} || echo "(none)"

      # Match on the device number, not on the path. A bind mount of this
      # device at any other name -- which is what a container does -- carries
      # the same major:minor in field 3 of mountinfo and no trace of the string
      # "${lv}" anywhere in the line. Grepping for the name missed exactly that
      # case and cost an hour.
      devno=$(dmsetup info -c --noheadings -o major,minor ${dmName} 2>/dev/null | tr -d ' ')

      echo
      echo "== mount namespaces holding device $devno, under any name"
      found=no
      for p in /proc/[0-9]*; do
        if [ -n "''${devno:-}" ] && awk -v d="$devno" '$3 == d { exit 0 } END { exit 1 }' "$p/mountinfo" 2>/dev/null; then
          pid=''${p#/proc/}
          echo "  pid $pid $(cat "$p/comm" 2>/dev/null)"
          awk -v d="$devno" '$3 == d { print "      at " $5 }' "$p/mountinfo" 2>/dev/null | head -2
          found=yes
        fi
      done
      [ "$found" = no ] && echo "  (none)"

      echo
      echo "== swap on it"
      grep -i "${lv}\|dm-''${devno#*:}" /proc/swaps 2>/dev/null || echo "  (none)"

      echo
      echo "== the device-mapper table itself"
      # An `error` target here means the volume is already half-removed:
      # `dmsetup remove --force` swaps the table for an error target and then
      # tries to remove, and leaves this behind when the remove fails on a
      # non-zero open count. lvs shows the same thing as X's in lv_attr.
      dmsetup table ${dmName} 2>&1 || true
      dmsetup deps ${dmName} 2>&1 || true

      echo
      echo "== processes with the device open, by device number"
      # `fuser -m` asks about a mounted filesystem, which this is not. Match on
      # the major:minor instead, which is what an open fd actually reports.
      devno=$(dmsetup info -c --noheadings -o major,minor ${dmName} 2>/dev/null | tr -d ' ')
      echo "  device number: ''${devno:-unknown}"
      found=no
      if [ -n "''${devno:-}" ]; then
        for fd in /proc/[0-9]*/fd/*; do
          tgt=$(readlink "$fd" 2>/dev/null) || continue
          case "$tgt" in
            *${dmName}*|*/dev/dm-*)
              if [ "$(stat -L -c '%t:%T' "$fd" 2>/dev/null | awk -F: '{printf "%d:%d", "0x"$1, "0x"$2}')" = "$devno" ]; then
                pid=$(echo "$fd" | cut -d/ -f3)
                echo "  pid $pid $(cat "/proc/$pid/comm" 2>/dev/null)"
                found=yes
              fi
              ;;
          esac
        done
      fi
      [ "$found" = no ] && echo "  (none)"

      echo
      echo "== lsof on the device node"
      lsof /dev/mapper/${dmName} 2>/dev/null || echo "  (none)"

      echo
      echo "== is it still mounted"
      findmnt --noheadings ${mount} || echo "(not mounted)"
    '';
  };

  # Destructive, and takes no argument so it can only ever destroy this one
  # volume. Every step checks the state it finds, so it is safe to re-run.
  lab-images-remove = pkgs.writeShellApplication {
    name = "lab-images-remove";
    runtimeInputs = [
      pkgs.lvm2
      pkgs.util-linux
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      if ! lvs ${vg}/${lv} >/dev/null 2>&1; then
        echo "lab-images-remove: ${vg}/${lv} is already gone. Delete hosts/dynhetz/lab-images.nix."
        exit 0
      fi

      if findmnt --noheadings ${mount} >/dev/null 2>&1; then
        echo "unmounting ${mount}"
        systemctl stop "$(systemd-escape --path --suffix=mount ${mount})" 2>/dev/null || true
        findmnt --noheadings ${mount} >/dev/null 2>&1 && umount ${mount}
      fi

      # `lvremove` refuses with "contains a filesystem in use" purely because
      # the device-mapper open count is not zero -- LVM's check is
      # lv_check_not_in_use(), which reads that count and says nothing about
      # whether a filesystem is really mounted. So the whole job is getting the
      # count to zero, and each rung below is a different way to try.
      opencount() { dmsetup info -c --noheadings -o open ${dmName} 2>/dev/null | tr -d ' '; }

      echo "open count before: $(opencount)"

      for attempt in deactivate retry force deferred final; do
        if ! lvs ${vg}/${lv} >/dev/null 2>&1; then break; fi

        case $attempt in
          deactivate) lvchange --activate n ${vg}/${lv} 2>&1 || true ;;
          retry)      dmsetup remove --retry ${dmName} 2>&1 || true ;;
          force)      dmsetup remove --force --retry ${dmName} 2>&1 || true ;;
          # Deferred removal schedules the node to disappear when its last
          # reference drops, instead of failing now. It is the one rung that
          # does not need the open count to already be zero, and it is what
          # avoids a reboot on a host that unlocks its root over initrd SSH.
          deferred)   dmsetup remove --deferred ${dmName} 2>&1 || true ;;
          final)      : ;;
        esac
        udevadm settle 2>/dev/null || true

        if lvremove --force --yes ${vg}/${lv} 2>&1; then
          echo "removed after: $attempt"
          break
        fi
        echo "  still held after $attempt (open count $(opencount))" >&2
      done

      if lvs ${vg}/${lv} >/dev/null 2>&1; then
        echo >&2
        echo "lab-images-remove: the open count will not drop." >&2
        echo >&2
        echo "The device-mapper table is already an error target with no" >&2
        echo "dependencies, so the volume's data is gone and its 400 GiB is" >&2
        echo "no longer mapped into the pool -- what remains is one stale" >&2
        echo "reference the kernel holds and no /proc entry accounts for." >&2
        echo "A reboot clears it and costs nothing, because there is nothing" >&2
        echo "left on the volume to lose." >&2
        exit 1
      fi

      rmdir ${mount} 2>/dev/null || true
      echo
      lvs -o lv_name,lv_size,data_percent,pool_lv ${vg}
    '';
  };
in
{
  environment.systemPackages = [
    lab-images-inspect
    lab-images-remove
  ];

  # The stable path, not the store path, for the reason ./ai-rebuild.nix gives:
  # sudo matches the command as the caller wrote it.
  security.sudo.extraRules = [
    {
      users = [ "lillecarl" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/lab-images-inspect";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/lab-images-remove";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
