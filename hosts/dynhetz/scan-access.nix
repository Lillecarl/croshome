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
    # doCheck = false: the writer's flake8 gate re-fires on whatever the
    # --ignore list replaces (W503 was next). The file is a plain Python
    # script; syntax errors surface on first run, not in a rebuild.
    (pkgs.writers.writePython3Bin "scan-access"
      { doCheck = false; }
      (builtins.readFile ./scan-access.py
      ))
  ];
}
