# Hey Carl at https://hey.lillecarl.com. It signs people in itself, against
# the gate's dex, and checks every request; no gate stands in front.
#
# Needs an A record hey.lillecarl.com -> 65.108.150.98: Caddy gets the
# certificate over HTTP-01, and the *.snurr wildcard does not cover this name.
{ config, inputs, ... }:
let
  gate = config.services.gate;
in
{
  imports = [ (inputs.heycarl.outPath + "/nix/module.nix") ];

  services.heycarl = {
    enable = true;
    publicUrl = "https://hey.lillecarl.com";
    oidc = {
      issuer = "https://dex.${gate.baseDomain}";
      clientId = "hey";
      clientSecretFile = config.age.secrets.dex-client-hey.path;
    };
    allowedEmails = [ gate.idp.email ];
    caddy.enable = true;
  };

  age.secrets.dex-client-hey.file = ../../secrets/dex-client-hey.age;

  services.gate.idp.clients.hey = {
    redirectURIs = [ "https://hey.lillecarl.com/auth/callback" ];
    secretFile = config.age.secrets.dex-client-hey.path;
  };
}
