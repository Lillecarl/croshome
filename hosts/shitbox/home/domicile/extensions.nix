# Browser extensions domicile loads unpacked, from their GitHub release zips.
#
# Not from the Web Store: domicile installs Web Store extensions without
# recording their permissions as granted, so Chromium disables them as a
# permissions increase at every start (Lillecarl/domicile#2). An unpacked
# extension's permissions are granted when it loads.
#
# `key` is the store's public key, so each keeps its store id: Bitwarden's
# desktop app takes biometric unlock only from that id, and the id stays across
# version bumps (an unpacked id otherwise comes from its path). Each key was
# checked to hash to its id.
{ pkgs }:
let
  unpacked =
    {
      pname,
      version,
      url,
      hash,
      key,
    }:
    pkgs.runCommand "${pname}-${version}"
      {
        src = pkgs.fetchzip {
          inherit url hash;
          stripRoot = false;
        };
        nativeBuildInputs = [ pkgs.jq ];
        inherit key;
      }
      ''
        cp -r $src $out
        chmod -R u+w $out
        jq --arg key "$key" '.key = $key' $src/manifest.json > $out/manifest.json
      '';
in
{
  # nngceckbapebfimnlniiiahkandclblb
  bitwarden = unpacked rec {
    pname = "bitwarden-chromium";
    version = "2026.11.0";
    url = "https://github.com/bitwarden/clients/releases/download/browser-v${version}/bit-dist-chrome-${version}.zip";
    hash = "sha256-jeF3W3mU2DmuXj2vlkcIO1HAjOryguOfoa5njUNgwVE=";
    key = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmqKbvreshyXRuN2gikeR1idqR6KL0Di89JZcMyD4bjJRZVmQO7aznSGSALIHzSAUGYocUYBNDOP5QAhImxXyQ1qG8+goXs93v9GzrNJETdVuCEhqBggC4/DFabryJZDiKvZ2Jl0DM7MsWdoybZPwrj70V3aJ/nVNOMkf868scNTMliwitCqqjT5baTANsG0DkZWQExD4lSXzSZHH9MEO8q0iZ7RRlNuGRBAkZgNV8FwZRsPKm/rwQ9dy3VpgLcmLp5GiMt+kAEncqKAkuRYnhVXXBsKqIyYTMjHSLkLnpfFySyOPLBdS617i/PGNiP/MT6Xy6z//v5NozUgaAZ4gJQIDAQAB";
  };
  # mlomiejdfkolichcflejclcbmpeaniij
  ghostery = unpacked rec {
    pname = "ghostery-chromium";
    version = "10.6.13";
    url = "https://github.com/ghostery/ghostery-extension/releases/download/v${version}/ghostery-chromium-${version}.zip";
    hash = "sha256-b5Xqcp6s/aX4k3e2hcAA+LxlmEi88niYhx4c5n/505A=";
    key = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDWKbhv4tbugT5f8XlKtXmjzhsWjGX+ILAnBL9AOzUA2nYu9Y2P8PAxbOHSRKeLE9zHYD2MzsGgBE4LlLKGV7p5FhrtURBMJrkN5RooOH/RkAPbAvyfJ+sku5qgg2Ijrf10cxXqED39WsTaa4ZWnnkOXl9Y7XMGbuolzBz2m+SfSwIDAQAB";
  };
}
