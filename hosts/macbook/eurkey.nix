{ lib, pkgs, ... }:
let
  # The upstream build compiles nothing. build-bundle.sh copies the keylayouts,
  # icons and localised strings out of src/ into a bundle, then writes
  # Info.plist and version.plist around them. So this needs no toolchain.
  eurkey-next = pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "eurkey-next";
    # Upstream tags releases by date. This is the newest tag.
    version = "2026.03.22";

    src = pkgs.fetchFromGitHub {
      owner = "felixfoertsch";
      repo = "EurKEY-Next";
      tag = finalAttrs.version;
      hash = "sha256-z34EHdZ0mbpfi8vBmlPMQs6fbpkMMIhXVhFdZaq4Vbg=";
    };

    # scripts/validate_layouts.py runs at the end of the build. It compares
    # every layout against the v1.3 specification. It imports only the standard
    # library, so plain python3 is enough.
    nativeBuildInputs = [ pkgs.python3 ];

    buildPhase = ''
      runHook preBuild

      # Without --version the script stamps the plists with today's date. The
      # output would then change on every build.
      #
      # The script first calls build-icons.sh, which regenerates the .icns files
      # from SVG. That step wants rsvg-convert and macOS' iconutil. iconutil is
      # not in the store, so rsvg-convert stays out too: the script then reports
      # SKIP and keeps the .icns files that upstream commits in src/icons. The
      # plutil lint step drops out the same way.
      bash scripts/build-bundle.sh --version ${finalAttrs.version}

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/Library/Keyboard Layouts"
      cp -R build/EurKEY-Next.bundle "$out/Library/Keyboard Layouts/"

      runHook postInstall
    '';

    meta = {
      description = "macOS keyboard layout for Europeans, coders and translators";
      homepage = "https://github.com/felixfoertsch/EurKEY-Next";
      # The layout itself. The EU flag icon on the legacy versions is
      # CC BY-NC-ND 3.0, which nixpkgs would call unfree.
      license = lib.licenses.gpl3Only;
      platforms = lib.platforms.darwin;
    };
  });
in
{
  # macOS discovers keyboard layouts by scanning /Library/Keyboard Layouts, and
  # it wants a real bundle directory there. A symlink into the store does not
  # work. So copy the tree in, the same way nix-darwin populates
  # /Applications/Nix Apps.
  #
  # After the first activation, log out and back in. Then add the layout in
  # System Settings > Keyboard > Input Sources > +. macOS keeps the list of
  # enabled input sources in cfprefsd, so nix cannot write it for you.
  system.activationScripts.postActivation.text = ''
    echo "setting up /Library/Keyboard Layouts..." >&2

    mkdir -p "/Library/Keyboard Layouts"

    rsyncFlags=(
      # The store normalises mtime, which leaves only file size to tell two
      # files apart. Checksums are the reliable comparison here.
      --checksum
      --archive
      # Removes files an older version of the bundle left behind. The trailing
      # slash on the source keeps --delete inside the bundle, so layouts
      # installed by hand next to it survive.
      --delete
      --chmod=-w
      --no-group
      --no-owner
    )

    ${lib.getExe pkgs.rsync} "''${rsyncFlags[@]}" \
      "${eurkey-next}/Library/Keyboard Layouts/EurKEY-Next.bundle/" \
      "/Library/Keyboard Layouts/EurKEY-Next.bundle"

    # --no-owner and --no-group only decide the owner of files rsync creates.
    # A bundle that a hand install put here first keeps its own owner, and
    # rsync leaves identical files alone, so state this instead of assuming it.
    chown -R root:wheel "/Library/Keyboard Layouts/EurKEY-Next.bundle"

    # The same hand install leaves com.apple.quarantine on every file it
    # unpacked, because the browser that downloaded the DMG set it. Nothing
    # nix copies in is quarantined, so clearing the whole tree is safe and
    # removes the flag from anything that came before.
    /usr/bin/xattr -c -r "/Library/Keyboard Layouts/EurKEY-Next.bundle"

    # loginwindow is not in lillecarl's preference domain. It reads the
    # system copy of HIToolbox instead, so selecting EurKEY for the account
    # alone leaves the initial login screen on Swedish. Copy the complete
    # preference file rather than reconstructing private HIToolbox keys and
    # layout IDs; this preserves the exact source that macOS accepted for the
    # user. The bundle has been installed above before this file is consumed
    # at the next boot.
    install -m 644 \
      "/Users/lillecarl/Library/Preferences/com.apple.HIToolbox.plist" \
      "/Library/Preferences/com.apple.HIToolbox.plist"

    # FileVault's pre-boot login happens before macOS can load either
    # HIToolbox plist or a custom layout. Its supported input source comes
    # from NVRAM; `en-US:0` is Apple's standard U.S. source. This also fixes
    # the regular login window, which was following the existing `en:7`
    # (Swedish) value instead of the system HIToolbox preference above.
    /usr/sbin/nvram 'prev-lang:kbd=en-US:0'
  '';
}
