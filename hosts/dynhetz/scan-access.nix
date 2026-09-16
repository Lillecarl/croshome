# The access scanner as a command on the host: ./scan-access.sh installed
# as `scan-access`, so the check is runnable by anyone who can read this
# repository and needs nothing from the store to run.
{
  pkgs,
  ...
}:
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "scan-access";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
        gnugrep
      ];
      text = builtins.readFile ./scan-access.sh;
    })
  ];
}
