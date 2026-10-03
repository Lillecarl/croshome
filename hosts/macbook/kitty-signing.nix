{ lib, ... }:
let
  # Empty disables signing: ad-hoc is a proven brick (see below), so no
  # signature beats a bad one. With a real identity, activation re-seals
  # as root, which also reaches the System keychain identity
  # non-interactively. `security find-identity -v -p codesigning
  # /Library/Keychains/System.keychain` lists candidates.
  signingIdentity = "Apple Development: icloud@lillecarl.com (L2KR4ZGFH3)";
in
{
  # nix-darwin rsyncs kitty.app into /Applications/Nix Apps with only the
  # executable seal the Nix build carried, which Notification Center will
  # not register. Re-seal the bundle after that rsync, so a kitty update
  # cannot silently drop notification rights. postActivation is the only
  # slot that runs after the rsync; extraActivation runs before it.
  system.activationScripts.postActivation.text = ''
    bundle='/Applications/Nix Apps/kitty.app'
    identity=${lib.escapeShellArg signingIdentity}
    if [ -n "$identity" ] && [ -d "$bundle" ]; then
      echo "re-sealing kitty.app for notifications..." >&2
      /usr/bin/codesign --force --deep --sign "$identity" "$bundle" || echo "kitty re-seal failed" >&2
    fi
  '';
}
