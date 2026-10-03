{ lib, pkgs, ... }:
let
  # Apple-issued identity from the System keychain, where root-time
  # activation can reach it non-interactively (login keychain stays
  # locked to root). `security find-identity -v -p codesigning
  # /Library/Keychains/System.keychain` lists candidates. Empty
  # disables signing: an unsigned bundle launches but cannot post
  # notifications; a botched seal bricks launch, so the script below
  # signs a staging copy and swaps it in only after strict verify.
  signingIdentity = "Apple Development: icloud@lillecarl.com (L2KR4ZGFH3)";
in
{
  # nix-darwin rsyncs kitty.app with only the executable seal the Nix
  # build carried, which Notification Center will not register. Re-seal
  # inside-out mirroring upstream's own seal: hardened runtime and
  # upstream's entitlements on every Mach-O, explicit bundle
  # identifier on the seal. A single --deep pass without entitlements
  # trips an AMFI launch constraint and the app stops starting.
  # postActivation is the only slot after the rsync; extraActivation
  # runs before it.
  system.activationScripts.postActivation.text = ''
    bundle='/Applications/Nix Apps/kitty.app'
    identity=${lib.escapeShellArg signingIdentity}
    entitlements=${./kitty-entitlements.plist}
    if [ -n "$identity" ] && [ -d "$bundle" ]; then
      work=$(mktemp -d -t kitty-signing.XXXXXXXX)
      ${lib.getExe pkgs.rsync} -a --copy-unsafe-links "$bundle/" "$work/kitty.app/"
      chmod -R u+w "$work/kitty.app"
      stage=$work/kitty.app
      cs() { /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" --keychain /Library/Keychains/System.keychain "$@"; }
      find "$stage/Contents/Resources" -type f -name '*.so' | while read -r m; do cs "$m"; done
      cs "$stage/Contents/kitty-quick-access.app/Contents/MacOS/kitty-quick-access"
      cs "$stage/Contents/kitty-quick-access.app"
      cs --entitlements "$entitlements" "$stage/Contents/MacOS/kitten"
      cs --entitlements "$entitlements" "$stage/Contents/MacOS/kitty"
      cs "$stage/Contents/MacOS/.kitty-wrapped"
      cs --identifier net.kovidgoyal.kitty --entitlements "$entitlements" "$stage"
      if /usr/bin/codesign --verify --deep --strict "$stage"; then
        echo "activating signed kitty.app..." >&2
        ${lib.getExe pkgs.rsync} -a --delete --checksum "$stage/" "$bundle/"
      else
        echo "kitty signing failed verification, live bundle untouched" >&2
      fi
      rm -rf "$work"
    fi
  '';
}
