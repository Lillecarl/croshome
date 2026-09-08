{
  pkgs,
  ...
}:
{
  # git-bug, a bug tracker that lives in the git repository it tracks. It
  # writes its issues to `refs/bugs/*` and its identities to
  # `refs/identities/*`, so nothing lands in the working tree and no service
  # holds the data.
  #
  # home-manager has no module for it, so this is the package plus the one
  # thing that is configurable. The package carries the fish, bash and zsh
  # completions and the man page, and home-manager's profile is on the path
  # each of those is read from.
  #
  # **Call it `git-bug`, never `git bug`.** git dispatches `git bug` to the
  # same binary, but ../home/claude/skills/jj-worktrees blocks a git
  # subcommand that is not on its read-only list, and `bug` is not. Verified:
  # `git bug version` in this repository is refused. The hook is right to
  # refuse it -- it writes -- and `git-bug` reaches the same program without
  # going through git.
  #
  # **The identity is per repository and nothing here can set it.** git-bug
  # stores it as a git object and points at it with a local `git-bug.identity`
  # key, so it is a hash that only exists inside one repository. Until it is
  # made, every write says "No identity is set". Once per repository:
  #
  #     git-bug user new --name lillecarl --email git@lillecarl.com \
  #       --non-interactive
  #
  # ../home/vcs.nix already holds that name and that address for git, and this
  # repository is one of the `personalRepos` that gets the personal one.
  #
  # **jj does not carry the bugs.** `jj git push` pushes bookmarks, so the bug
  # and identity refs stay behind; `git-bug push <remote>` sends them and
  # `git-bug pull` fetches them. jj leaves them alone otherwise: checked in a
  # colocated repository, `refs/bugs/*` sits next to `refs/jj/*` and a jj
  # snapshot does not disturb it.
  home.packages = [ pkgs.git-bug ];

  # The one documented git config key, from `git-bug webui --help`.
  #
  # No, because two of the three machines this configuration builds are
  # headless servers, and opening a browser there is either an error or a
  # browser on the wrong machine. `git-bug webui --open` still asks for it on
  # a machine that has one.
  programs.git.settings."git-bug".webui.open = false;
}
