# sops-nix trial: dummy values, decrypted to /run/secrets and read by nothing.
# agenix still serves every real consumer.
{ config, ... }:
{
  croshome.secrets.enable = true;

  sops.secrets = {
    "aid/deepseek" = { };
    "litellm/zen" = { };
    "litellm/go" = { };
    "litellm/master" = { };
    pymux_anthropic_key.owner = "lillecarl";
    pynixd_aws = { };
    wg_key.sopsFile = ../../secrets/sops/dc1.yaml;
  };

  # What aid-env and litellm-env become: one file built from single keys.
  sops.templates = {
    aid-env = {
      owner = "lillecarl";
      content = ''
        DEEPSEEK_API_KEY=${config.sops.placeholder."aid/deepseek"}
      '';
    };
    litellm-env = {
      owner = "lillecarl";
      content = ''
        OPENCODE_ZEN_API_KEY=${config.sops.placeholder."litellm/zen"}
        OPENCODE_GO_API_KEY=${config.sops.placeholder."litellm/go"}
        LITELLM_MASTER_KEY=${config.sops.placeholder."litellm/master"}
      '';
    };
  };

  home-manager.users.lillecarl.croshome.userSecrets = {
    kagi_token = { };
    migadu_pass = { };
  };
}
