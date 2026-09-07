# TopoLVM: disks for the VMs, carved out of this host's LVM.
#
# KubeVirt gives a VM a disk by giving its pod a volume. TopoLVM is a CSI
# driver that makes those volumes logical volumes on the node, so a Talos root
# disk gets its own LV out of the thin pool rather than a file on the root
# filesystem, and `lvs` shows what the cluster is holding.
#
# One LV per volume, not one raw LV per disk. ./cdi.nix has to ask for
# Filesystem volumes rather than Block ones -- read that file for why -- so the
# LV carries xfs and the VM's disk is a file on it. The LV, its size and its
# lifetime are still per-volume, which is what this driver is for.
#
# There is one node, so node-local storage costs nothing that a network volume
# would buy back. A PersistentVolume that only one node can mount is only a
# limit when there is a second node to move to.
#
# Thin, because the volume group has no room
# ------------------------------------------
# `mainpool` has zero free extents. All of it is already `root` and the thin
# pool `thinpool`, so there is nothing to carve a thick logical volume out of
# and no space to grow the pool with. `thinpool` is therefore where TopoLVM
# has to allocate, which makes the device class below `type: thin`.
#
# `overprovision-ratio` is 1.0, which means TopoLVM never promises more than
# the pool holds. Free space is the pool times that ratio, minus every thin
# volume already in it, whoever made it -- so a second consumer is subtracted
# rather than ignored. Measured while the libvirt lab still had a 400 GiB
# volume here: the node advertised capacity.topolvm.io/thin = 273330208768,
# the 654 GiB pool less that claim. That volume is gone and TopoLVM is now the
# only consumer, so the whole pool is the cluster's.
#
# A ratio above 1.0 is what thin provisioning is for, and it is still the wrong
# choice on one node. Nothing here watches the pool, and a thin pool that runs
# out of data goes read-only under every volume at once.
#
# One number here is worth watching: the pool's metadata volume is 84 MiB. That
# is LVM's own computed default for a pool this size, not a mistake, but a thin
# pool whose metadata fills goes read-only and needs an offline repair. Adding
# a second consumer is the moment to check it, with `lvs -a mainpool` and its
# Meta% column.
#
# What is not installed, and why
# ------------------------------
#   the scheduler extender  Off, and off by default in the chart. It scores
#                           nodes by free space in a device class. There is one
#                           node, so every score is the same score.
#   the pod mutating webhook  Off, and off by default. It exists to add the
#                           capacity requests that extender reads. With no
#                           extender there is nothing to read them, and turning
#                           it on is what would drag in cert-manager -- the
#                           chart's Certificate and Issuer objects are gated on
#                           this one value.
{ pkgs, ... }:
{
  helm.releases.topolvm = {
    namespace = "topolvm-system";

    chart = pkgs.fetchHelm {
      repo = "https://topolvm.github.io/topolvm";
      chart = "topolvm";
      version = "17.2.0";
      sha256 = "sha256-kdOVGleV9S8tXvqEYWLFD0OaPXdwIch0kh2nDCg8iFE=";
    };

    # No includeCRDs. This chart keeps its CustomResourceDefinitions under
    # templates/ rather than crds/, so `helm template` renders them like any
    # other object and the flag would change nothing.

    # Helm renders this chart's PriorityClass as `value: 1e+06`, and that is
    # Helm rather than anything here: it reads a values file into float64 and
    # prints it back with Go's %v, which goes to scientific notation at 1e6 and
    # above. `1e+06` has no decimal point, so YAML 1.1 calls it a string, and
    # the apply then fails with `.value: expected numeric (int or float), got
    # string`.
    #
    # Fixed after rendering rather than by choosing a smaller number in
    # `values`, because a smaller number does not fix it -- 1000001 renders as
    # `1.000001e+06` and only a value below 1e6 escapes the notation, which
    # would be picking the class's priority to work around a printf.
    #
    # Verified against the chart with `helm template` directly, so no bug is
    # being papered over on the easykubenix side.
    overrides = [
      (object: if object.kind or null == "PriorityClass" then object // { value = 1000000; } else object)
    ];

    values = {
      # One node, so one replica. The CSI controller is a two-replica
      # Deployment with an anti-affinity that keeps the replicas on separate
      # nodes, and there is no separate node -- the second stayed Pending. Same
      # reason as ./kubevirt.nix's infra.replicas.
      controller.replicaCount = 1;

      # lvmd is the piece that actually calls lvcreate, and `managed` runs it
      # as a DaemonSet rather than as a service on the node. That is the whole
      # reason storage can be a deploy step: the host configuration stays out
      # of it, and ../default.nix explains why that split is wanted.
      lvmd = {
        managed = true;

        # The one thing that makes this work on NixOS.
        #
        # lvmd runs in a container and does not use the LVM in its own image.
        # It nsenters into PID 1's namespaces and runs the node's own lvm, so
        # that one program manages the volume group. Its default for that is
        # `/sbin/lvm`, and this node has no /sbin at all -- lvmd crash-loops
        # with `nsenter: failed to execute /sbin/lvm: No such file or
        # directory`.
        #
        # `lvm-command-prefix` replaces the whole argument list, nsenter and
        # all, so the flags below are upstream's own and only the last entry
        # differs. `--lvm-path` would set just that entry, and upstream
        # deprecated it in favour of this.
        #
        # /run/current-system and not a store path: the tool that manages the
        # volume group should be the one this machine is running. A store path
        # resolved from ../default.nix's evaluation would stay on whatever lvm2
        # that evaluation saw, which is not necessarily the node's.
        #
        # "1" is quoted because it is nsenter's `-t` argument. The setting is a
        # list of strings, and an unquoted 1 is a YAML integer that lvmd
        # refuses to load.
        additionalLVMDYamlContent.lvm-command-prefix = [
          "/usr/bin/nsenter"
          "-m"
          "-u"
          "-i"
          "-n"
          "-p"
          "-t"
          "1"
          "/run/current-system/sw/bin/lvm"
        ];

        # Replaces the chart's example class rather than adding to it -- Helm
        # values replace lists, they do not merge them.
        deviceClasses = [
          {
            name = "thin";
            volume-group = "mainpool";
            type = "thin";
            thin-pool = {
              name = "thinpool";
              overprovision-ratio = 1.0;
            };
            default = true;
          }
        ];
      };

      # `isDefaultClass`, because this is the only storage in the cluster. A
      # PersistentVolumeClaim that names no class is asking for whatever the
      # cluster has, and the answer is this.
      #
      # xfs is already in /proc/filesystems on this node, so a volume mounts
      # with no module load from inside a container.
      #
      # WaitForFirstConsumer is the chart's own default and stays. TopoLVM
      # cannot create an LV until it knows which node the pod lands on, and
      # Immediate would make it guess.
      storageClasses = [
        {
          name = "topolvm-provisioner";
          storageClass = {
            fsType = "xfs";
            isDefaultClass = true;
            volumeBindingMode = "WaitForFirstConsumer";
            allowVolumeExpansion = true;
            reclaimPolicy = "Delete";
          };
        }
      ];
    };
  };
}
