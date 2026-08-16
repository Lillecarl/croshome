{ ... }:
{
  # FUSE cannot come from nixpkgs on darwin: macfuse-stubs is build-time only.
  # FUSE-T is the kext-less implementation -- it serves an NFSv4 loopback
  # instead of a kernel extension, so it needs no kext approval, no Reduced
  # Security and no reboot. It is only distributed through Homebrew.
  homebrew = {
    enable = true;
    # cleanup stays at "none" so this does not touch anything else brew
    # already manages on this machine.
    taps = [ "macos-fuse-t/homebrew-cask" ];
    casks = [
      "fuse-t"
      # nixpkgs' sshfs is linked against macFUSE's ABI and greets every mount
      # with "fuse: warning: library too old" when FUSE-T answers instead --
      # libfuse truncates the operations struct to what it actually implements
      # and silently drops the rest. This is the same sshfs built against
      # FUSE-T, so the two agree.
      "fuse-t-sshfs"
    ];
  };
}
