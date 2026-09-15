{ pkgs, ... }:
{
  home.packages = [
    # One command for the thing Apple documents as two. `dscacheutil
    # -flushcache` alone clears nothing on modern macOS: the cache lives in
    # mDNSResponder, and only the HUP makes it drop it. Both run through sudo,
    # so this prompts for a password when it runs.
    (pkgs.writeShellScriptBin "flush-dns" ''
      /usr/bin/sudo /usr/bin/dscacheutil -flushcache
      /usr/bin/sudo /usr/bin/killall -HUP mDNSResponder
    '')
  ];
}
