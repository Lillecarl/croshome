{
  lib,
  stdenv,
  writeShellApplication,
  age,
  age-plugin-tpm,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  jq,
  keyutils,
  sops,
}:
writeShellApplication {
  name = "secrets";
  # The keyring and the TPM are Linux-only; darwin needs a Keychain branch.
  runtimeInputs = [
    age
    coreutils
    findutils
    gnugrep
    gnused
    jq
    sops
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    age-plugin-tpm
    keyutils
  ];
  text = builtins.readFile ./secrets.bash;
}
