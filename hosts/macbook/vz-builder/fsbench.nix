# Filesystem benchmark for the builder guest's ephemeral disks.
#
# Runs as root inside the guest against a whole spare virtio disk, which it
# reformats again and again: /dev/vdb, the swap disk, by default. It takes
# swap off that disk first, so run it with no build in flight.
#
#   nix build --impure --expr \
#     '(import /etc/nixpkgs { system = "aarch64-linux"; }).callPackage ./hosts/macbook/vz-builder/fsbench.nix { }'
#   vzrun --root ./result/bin/fsbench > fsbench.tsv
#
# One TSV row per measurement on stdout; progress on stderr.
{
  writeShellApplication,
  coreutils,
  util-linux,
  e2fsprogs,
  xfsprogs,
  btrfs-progs,
  f2fs-tools,
  fio,
  jq,
  gawk,
  path,
}:
writeShellApplication {
  name = "fsbench";
  runtimeInputs = [
    coreutils
    util-linux
    e2fsprogs
    xfsprogs
    btrfs-progs
    f2fs-tools
    fio
    jq
    gawk
  ];
  text = ''
    dev=''${FSBENCH_DEV:-/dev/vdb}
    mnt=''${FSBENCH_MNT:-/mnt/fsbench}
    runtime=''${FSBENCH_RUNTIME:-10}
    size=''${FSBENCH_SIZE:-4G}
    variants=''${FSBENCH_VARIANTS:-raw ext4 ext4-bigalloc16k xfs xfs-16k btrfs f2fs}
    blocksizes=''${FSBENCH_BS:-4k 16k 64k 1m}
    patterns=''${FSBENCH_PATTERNS:-randread randwrite read write}
    # A many-small-files tree, like the sources and outputs a build writes.
    tree=${path}

    log() { echo "fsbench: $*" >&2; }
    now() { date +%s.%N; }
    elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }

    mkfs_for() {
      case $1 in
        ext4) mkfs.ext4 -q -F "$dev" ;;
        ext4-bigalloc16k) mkfs.ext4 -q -F -O bigalloc -C 16384 "$dev" ;;
        xfs) mkfs.xfs -q -f "$dev" ;;
        xfs-16k) mkfs.xfs -q -f -b size=16384 "$dev" ;;
        btrfs) mkfs.btrfs -q -f "$dev" ;;
        f2fs) mkfs.f2fs -q -f "$dev" ;;
      esac
    }

    mount_opts() {
      case $1 in
        ext4*) echo noatime,nobarrier ;;
        xfs*) echo noatime ;;
        btrfs) echo noatime,nobarrier ;;
        f2fs) echo noatime,nobarrier ;;
      esac
    }

    fio_row() {
      local variant=$1 pattern=$2 bs=$3 target=$4
      local json
      if ! json=$(fio --name=b --filename="$target" --size="$size" --rw="$pattern" --bs="$bs" \
          --ioengine=io_uring --direct=1 --iodepth=32 --numjobs=1 --time_based \
          --runtime="$runtime" --ramp_time=2 --group_reporting --output-format=json 2>/dev/null); then
        printf '%s\tfio\t%s\t%s\tfailed\t\t\n' "$variant" "$pattern" "$bs"
        return
      fi
      jq -r --arg v "$variant" --arg p "$pattern" --arg bs "$bs" '
        .jobs[0] as $j
        | (if ($p | test("read")) then $j.read else $j.write end) as $s
        | [$v, "fio", $p, $bs, ($s.iops | floor), ($s.bw_bytes / 1048576 | . * 10 | floor / 10),
           ($s.clat_ns.percentile["99.000000"] // 0 | . / 1000 | floor)]
        | @tsv' <<<"$json"
    }

    tree_rows() {
      local variant=$1 t0 t1
      t0=$(now)
      cp -a /dev/shm/fsbench-tree "$mnt/tree"
      sync
      t1=$(now)
      printf '%s\ttree\tcopy+sync\t\t\t\t%s\n' "$variant" "$(elapsed "$t0" "$t1")"
      t0=$(now)
      rm -rf "$mnt/tree"
      sync
      t1=$(now)
      printf '%s\ttree\trm+sync\t\t\t\t%s\n' "$variant" "$(elapsed "$t0" "$t1")"
    }

    restore() {
      umount "$mnt" 2>/dev/null || true
      rm -rf /dev/shm/fsbench-tree
      if ! { mkswap -L vzswap "$dev" >/dev/null && swapon "$dev"; }; then
        log "could not restore swap on $dev"
      fi
    }

    swapoff "$dev" 2>/dev/null || true
    trap restore EXIT
    mkdir -p "$mnt"
    log "staging $tree in /dev/shm"
    cp -a "$tree" /dev/shm/fsbench-tree
    chmod -R u+w /dev/shm/fsbench-tree
    printf 'variant\tkind\ttest\tbs\tiops\tMiB/s\tp99_us_or_seconds\n'
    for variant in $variants; do
      log "$variant"
      blkdiscard -f "$dev"
      if [ "$variant" = raw ]; then
        for pattern in $patterns; do
          for bs in $blocksizes; do fio_row raw "$pattern" "$bs" "$dev"; done
        done
        continue
      fi
      t0=$(now)
      if ! mkfs_for "$variant" >/dev/null 2>&1; then
        printf '%s\tmkfs\tfailed\t\t\t\t\n' "$variant"
        continue
      fi
      t1=$(now)
      printf '%s\tmkfs\tformat\t\t\t\t%s\n' "$variant" "$(elapsed "$t0" "$t1")"
      if ! mount -o "$(mount_opts "$variant")" "$dev" "$mnt" 2>/dev/null; then
        printf '%s\tmount\tfailed\t\t\t\t\n' "$variant"
        continue
      fi
      for pattern in $patterns; do
        for bs in $blocksizes; do fio_row "$variant" "$pattern" "$bs" "$mnt/fio.dat"; done
      done
      rm -f "$mnt/fio.dat"
      tree_rows "$variant"
      umount "$mnt"
    done
  '';
}
