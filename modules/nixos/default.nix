# Every NixOS option module in this directory. Each one sets nothing until a
# host enables it, so importing them all is free.
{
  imports = [
    ./ai-rebuild.nix
    ./btrfs.nix
    ./nix-gc-sudo.nix
    ./pynixd.nix
  ];
}
