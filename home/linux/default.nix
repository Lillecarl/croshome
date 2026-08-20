{
  pkgs,
  ...
}:
{
  imports = [
    ./emacs.nix
    ./fonts.nix
    ./foot.nix
  ];

  # Only what genuinely cannot work on macOS belongs here, and "genuinely" is
  # decided by running the binary on darwin -- not by meta.platforms, not by
  # whether the build goes green. wireguard-tools, sbomnix and every agent CLI
  # passed that test, so they are in ../packages.nix and ../agents.nix. What is
  # left below is a kernel API, the administration tools that read /proc and
  # /sys, and two Wayland tools.
  home.packages = with pkgs; [
    # inotify is a Linux kernel API with no macOS equivalent in this package.
    inotify-tools

    # Administration tools that read a Linux kernel interface and would have
    # nothing to read on macOS: /proc, /sys, or a netlink socket. The tools
    # that do the same job on both platforms are in ../packages.nix.
    #
    # `lspci` and `lsusb` build on darwin and their nixpkgs meta says so, but
    # they walk /sys/bus, so the rule this file states -- run it there -- puts
    # them here.
    dmidecode # what the firmware says the hardware is, without opening the box
    ethtool # link speed, duplex, driver, and the NIC's own error counters
    iotop # which process is doing the I/O, over the taskstats netlink socket
    lshw # one tree of the whole machine, and `lshw -json` for a script
    pciutils # lspci
    psmisc # fuser, killall, pstree
    sysstat # iostat, mpstat, pidstat, sar -- the numbers over time, not now
    usbutils # lsusb

    # net-tools, minus the programs that would shadow something better.
    #
    # `netstat`, `ifconfig`, `route` and `arp` earn their place: half the
    # documentation in the world still uses them, and `netstat -tulpn` is
    # muscle memory. `ss` and `ip` replace all four and are already in the
    # system path, so reach for those first.
    #
    # The package also carries `hostname`, and that one must not be installed.
    # It is older than the `hostname-debian` in the system path and has no
    # `-I`, the flag that prints the addresses. home.packages comes before the
    # system path, so installing net-tools whole would quietly take `-I` away.
    # The rest -- mii-tool, nameif, plipconfig, rarp, slattach -- is dropped
    # for being obsolete.
    (runCommand "net-tools-net-only" { } ''
      mkdir -p $out/bin $out/share/man/man8
      for tool in arp ifconfig netstat route; do
        ln -s ${nettools}/bin/$tool $out/bin/$tool
        ln -s ${nettools.man}/share/man/man8/$tool.8.gz $out/share/man/man8/$tool.8.gz
      done
    '')

    # Wayland: the protocol proxy and the clipboard tool. The MacBook reaches
    # Linux applications through Cocoa-Way, which brings its own waypipe, and
    # its clipboard is pbcopy -- see home/fish/functions/copy.fish.
    waypipe
    wl-clipboard
  ];
}
