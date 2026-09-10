{
  lib,
  stdenv,
  fetchurl,
  cpio,
  gzip,
}:
stdenv.mkDerivation {
  pname = "nextcloud-client";
  version = "34.0.2";

  src = fetchurl {
    url = "https://github.com/nextcloud-releases/desktop/releases/download/v34.0.2/Nextcloud-34.0.2.pkg.tbz";
    sha256 = "a91924e30641f61e09cefc02fe7cb7941426efd0fba721839779f01b2690c179";
  };

  nativeBuildInputs = [ cpio gzip ];

  # This derivation runs Apple's pkgutil to expand the pkg. It lives in
  # /usr/sbin, which the build sandbox does not expose, so run outside the
  # sandbox. The output is reproducible and verifiable, and this is darwin
  # only, so the trade-off is contained.
  __noChroot = true;

  # The payload carries a Developer ID signature (with hardened runtime) that
  # covers the whole bundle, including the nested FinderSyncBroker login item
  # and the FileProvider/FinderSync extensions. macOS will not run those
  # helpers unless that signature is intact, so do not let Nix's fixup strip
  # it, and do not replace it with an adhoc one.
  dontStrip = true;

  # nixpkgs' nextcloud-client is lib.platforms.linux only, so there is no
  # darwin build to wrap. The official macOS release ships only a .pkg
  # (and its .tbz), whose payload is exactly a self-contained Nextcloud.app
  # in /Applications. Extract that bundle rather than running the pkg
  # installer, which needs root. nix-darwin then rsyncs the .app into
  # /Applications/Nix Apps like any other darwin app.
  #
  # pkgutil (Apple's own tool, present on every macOS) expands the pkg
  # without running its scripts. nixpkgs' xar cannot open this archive, so
  # this does not use it.
  unpackPhase = ''
    mkdir src && tar -xjf $src -C src
    inner=$(find src -name '*.pkg' | head -1)
    /usr/sbin/pkgutil --expand "$inner" expanded
    cat expanded/*/Payload | gunzip -c > payload.cpio
    mkdir payload && cd payload && cpio -id < ../payload.cpio
  '';

  installPhase = ''
    mkdir -p $out/Applications
    cp -R "$(pwd)"/Applications/Nextcloud.app $out/Applications/
  '';

  meta = {
    description = "Nextcloud desktop sync client";
    homepage = "https://nextcloud.com/";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.darwin;
  };
}