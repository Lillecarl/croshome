{
  lib,
  stdenv,
  buildPythonApplication,
  hatchling,
  pytestCheckHook,
  age,
  age-plugin-tpm,
  keyutils,
  openssh,
  sops,
  ssh-to-age,
}:
buildPythonApplication {
  pname = "croshome-secrets";
  version = "0.1.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./src
      ./tests
    ];
  };

  build-system = [ hatchling ];

  # macOS stores the key with /usr/bin/security, which is not a package.
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath (
      [
        age
        openssh
        sops
        ssh-to-age
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        age-plugin-tpm
        keyutils
      ]
    ))
  ];

  nativeCheckInputs = [ pytestCheckHook ];
  pythonImportsCheck = [
    "croshome_secrets.cli"
    "croshome_secrets.keys"
    "croshome_secrets.keystore"
  ];

  meta = {
    description = "Front end to sops for croshome's secrets/sops";
    license = lib.licenses.mit;
    mainProgram = "secrets";
  };
}
