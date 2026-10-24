# Every NixOS option module in this directory. Each one sets nothing until a
# host enables it, or sets only lazy config.lib scripts, so importing them all
# is free.
{
  imports = [
    ./ai-rebuild.nix
    ./btrfs.nix
    ./gate.nix
    ./installscript.nix
    ./nix-gc-sudo.nix
    ./pynixd.nix
  ];
}
