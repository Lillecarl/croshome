# The access scanner as a command on the host: ./scan-access.py installed as
# `scan-access`, so the check is runnable by anyone who can read this
# repository and needs nothing from the store to run. jj comes from the
# caller's PATH, exactly as it did for the bash version this replaces -- the
# wrapper's injected errexit kept killing that one mid-run.
{
  pkgs,
  ...
}:
{
  environment.systemPackages = [
    (pkgs.writers.writePython3Bin "scan-access" { } (
      builtins.readFile ./scan-access.py
    ))
  ];
}
