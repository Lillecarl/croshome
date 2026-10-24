# Temporary: passwordless root for lillecarl while the agent moves mainpool
# from the thin pool to thick volumes (User's grant, 2026-10-24). Remove this
# file when the migration is done.
{
  security.sudo.extraRules = [
    {
      users = [ "lillecarl" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
