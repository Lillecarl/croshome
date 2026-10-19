{
  lib,
  fetchFromGitHub,
  pydd,
}:
(pydd.rust.cargo {
  project = fetchFromGitHub {
    owner = "laulauland";
    repo = "jj-hunk";
    tag = "v0.4.1";
    hash = "sha256-lFuYTg6TW/Lsz4wwaaWFi37F2aGKpLwQgq40VTdDUKE=";
  };
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      description = "Programmatic hunk selection for jj (Jujutsu)";
      homepage = "https://github.com/laulauland/jj-hunk";
      license = lib.licenses.mit;
    };
  })
