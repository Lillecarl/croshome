# Hey Carl at https://hey.lillecarl.com, behind the gate.
#
# Needs an A record hey.lillecarl.com -> 65.108.150.98 before the first switch:
# Caddy gets the certificate over HTTP-01, and the *.snurr wildcard does not
# cover this name.
{ config, inputs, ... }:
{
  imports = [ (inputs.heycarl.outPath + "/nix/module.nix") ];

  services.heycarl = {
    enable = true;
    publicUrl = "https://hey.lillecarl.com";
  };

  age.secrets.dex-client-hey.file = ../../secrets/dex-client-hey.age;

  services.gate.apps.hey = {
    host = "hey.lillecarl.com";
    upstream = "unix://${config.services.heycarl.kernelSocket}";
    clientSecretFile = config.age.secrets.dex-client-hey.path;
    # The kernel socket is 0660 to this group.
    groups = [ "heycarl" ];
    # Android's install service fetches the manifest and icons without the
    # session cookie. Webhooks (calls, calendar push) check their own secret.
    publicRoutes = [
      "^/manifest[.]webmanifest"
      "^/icons/"
      "^/api/public/"
    ];
    apiRoutes = [ "^/api/" ];
  };
}
