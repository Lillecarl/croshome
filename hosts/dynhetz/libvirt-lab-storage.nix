# Backing storage for the lab VMs (see ./libvirt-lab-net.nix for their
# networking, and ./libvirt.nix for libvirtd itself).
#
# ./disko.nix leaves `mainpool/thinpool` -- 654 GiB, the whole VG minus
# the 250 GiB root LV -- unformatted, for VM disks. Getting VM disks
# into it needs this file, for two reasons that only show up once you
# try:
#
#  - The VG has no free extents at all. thinpool's size is "100%", so
#    everything not already root is inside the thin pool. Confirmed on
#    the machine (libvirt reporting the VG: 904.72 GiB capacity, 904.72
#    GiB allocated, 0 B available), not assumed. So a plain thick LV
#    can't be created, and a thin pool can't be shrunk to make room --
#    LVM supports growing a thin pool, never reducing one.
#
#  - libvirt's own "logical" storage pool can't allocate out of a thin
#    pool. Its backend only ever runs `lvcreate` with --name/--type/
#    --virtualsize (checked against the shipped
#    libvirt_storage_backend_logical.so, again not assumed) -- there is
#    no --thinpool/--thin anywhere in it. --virtualsize is the old
#    snapshot-based sparse LV, not a thin volume.
#
# So libvirt can't be pointed at the thin pool directly. What it can use
# is a directory. This carves one thin LV out of the pool, puts XFS on
# it, and mounts it -- Terraform then declares a libvirt `dir` pool on
# that path and owns every individual VM disk inside it as a qcow2. The
# VM storage still lives on LVM thin, which is the point; only the layer
# libvirt talks to changes.
#
# The LV is thin, and XFS is mounted with `discard`, so a deleted VM
# disk hands its extents back to the pool instead of holding them.
#
# The size is a ceiling, not a reservation -- a thin LV consumes only
# what is written to it, so an unused gigabyte here costs nothing. It is
# still deliberately well under the pool's 654 GiB rather than close to
# it: the filesystem cannot then promise more space than the pool can
# actually deliver, however many other things start using the pool
# later. 200 GiB holds roughly eight 24 GiB lab nodes plus their base
# images. Growing it later is `lvextend` followed by `xfs_growfs`, both
# online.
#
# Note that changing this number only affects a machine that does not
# have the LV yet: the service below creates and never resizes, and XFS
# cannot shrink at all, so making an existing volume smaller means
# destroying it and its contents by hand. That is a deliberate refusal
# to have an activation script silently reformat a disk.
{ pkgs, ... }:
let
  vg = "mainpool";
  thinPool = "thinpool";
  lv = "lab-images";
  virtualSize = "200G";
  mountPoint = "/var/lib/libvirt/lab-images";
in
{
  systemd.services.libvirt-lab-storage = {
    description = "Create the thin LV that backs the lab VM storage pool";
    wantedBy = [ "multi-user.target" ];
    # Deliberately no `after = [ "local-fs.target" ]`: the mount below
    # is itself part of local-fs.target, so ordering this service after
    # that target and the mount after this service is a cycle, and
    # systemd breaks it by dropping the mount. Nothing here needs the
    # target anyway -- the root filesystem is on this same VG, so LVM is
    # up long before any of this runs.
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.lvm2
      pkgs.xfsprogs
      pkgs.util-linux
    ];
    script = ''
      set -euo pipefail

      # Every step below is skipped if it's already been done, so this
      # is safe to rerun on every boot and every activation.
      if ! lvs --noheadings -o lv_name ${vg}/${lv} >/dev/null 2>&1; then
        lvcreate --thin ${vg}/${thinPool} --virtualsize ${virtualSize} --name ${lv}
      fi

      # A thin LV isn't necessarily active after a fresh boot.
      lvchange --activate y ${vg}/${lv}

      # blkid exits non-zero when the device holds no filesystem, which
      # is exactly the "first run" case -- and the only case where
      # writing a new filesystem is correct. Anything already there is
      # left alone.
      if ! blkid /dev/${vg}/${lv} >/dev/null 2>&1; then
        mkfs.xfs /dev/${vg}/${lv}
      fi

      install -d -m 0711 ${mountPoint}
    '';
  };

  systemd.mounts = [
    {
      what = "/dev/${vg}/${lv}";
      where = mountPoint;
      type = "xfs";
      # discard: freeing a qcow2 returns the extents to the thin pool.
      options = "defaults,discard";
      # A mount unit is part of local-fs.target by default, and a
      # service is ordered after sysinit.target by default, which is
      # itself after local-fs.target. Together with this mount needing
      # the service that creates its LV, that closes a cycle
      # (local-fs.target -> this mount -> the service -> sysinit.target
      # -> local-fs.target) and systemd drops units to break it. This
      # isn't an early-boot filesystem -- nothing before libvirtd wants
      # it -- so it opts out of the default ordering and states what it
      # actually needs instead.
      unitConfig.DefaultDependencies = "no";
      requires = [ "libvirt-lab-storage.service" ];
      after = [ "libvirt-lab-storage.service" ];
      before = [
        "libvirtd.service"
        "umount.target"
      ];
      # Restores what DefaultDependencies would have given us for
      # shutdown: without this the mount is never taken down cleanly.
      conflicts = [ "umount.target" ];
      wantedBy = [ "multi-user.target" ];
    }
  ];
}
