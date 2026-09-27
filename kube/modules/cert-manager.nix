# cert-manager, for the webhook certificates of ./cluster-api.nix. Each
# Cluster API controller serves a webhook and asks cert-manager for its
# serving certificate; nothing else here uses it.
#
# The release YAML, fetched as ./kubevirt.nix does. It carries its own
# Namespace.
{ pkgs, ... }:
let
  version = "1.21.2";
in
{
  importyaml.cert-manager.src = pkgs.fetchurl {
    url = "https://github.com/cert-manager/cert-manager/releases/download/v${version}/cert-manager.yaml";
    hash = "sha256-4DtmjshnUhSvawpnFpnQiPJgH6OHjg2+G0HT/q/Rh58=";
  };
}
