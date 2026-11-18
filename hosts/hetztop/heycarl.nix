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
      clientSecretFile = config.sops.secrets.dex-client-hey.path;
    };
    google = {
      clientId = "665224742694-e858j6m96c80r9hp1h0u70purmsc8raa.apps.googleusercontent.com";
      clientSecretFile = config.sops.secrets.heycarl-google-client.path;
      tokenKeyFile = config.sops.secrets.heycarl-google-token-key.path;
    };
    allowedEmails = [ gate.idp.email ];
    caddy.enable = true;
  };

  sops.secrets = {
    dex-client-hey = { };
    heycarl-google-client = { };
    heycarl-google-token-key = { };
  };

  services.gate.idp.clients.hey = {
    redirectURIs = [ "https://hey.lillecarl.com/auth/callback" ];
    secretFile = config.sops.secrets.dex-client-hey.path;
  };
}
