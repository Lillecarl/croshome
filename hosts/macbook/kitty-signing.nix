{ lib, ... }:
let
  # Empty means ad-hoc, which is a proven brick: binding the real
  # Info.plist puts the bundle under an AMFI launch constraint that
  # only an Apple-issued signature satisfies, so the app no longer
  # starts at all. Set this to an "Apple Development: Name (TEAMID)"
  # identity once Xcode has issued one; `security find-identity -v -p
  # codesigning` prints the exact string.
  signingIdentity = "";
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
