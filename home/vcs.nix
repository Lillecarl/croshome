{
  config,
  lib,
  selfStr,
  ...
}:
let
  # This configuration is personal, so it commits under the personal address
  # even though the default is now the work one. Add a path here to give
  # another repo the same treatment.
  personalRepos = [ selfStr ];
  personalEmail = "git@lillecarl.com";

  # ../secrets/pgp-keys.nix, written by ../secrets/pgp-create. Both entries are
  # null until that script has run once, ever, so this file has to evaluate
  # either way: `signing` is what every block below asks.
  #
  # Signing follows the same split as the address. The work key is the default
  # and the personal key covers `personalRepos`, so the key and the address on
  # a commit always name the same person. A commit signed by the work key under
  # a personal address is worse than no signature: it says the two identities
  # are one.
  pgp = import ../secrets/pgp-keys.nix;
  signing = pgp.work != null && pgp.personal != null;
in
{
  config = {
    programs.jujutsu = {
      enable = true;
      settings = {
        user.name = "lillecarl";
        # The work address, on every machine. It used to default to
        # git@lillecarl.com with only the MacBook overriding it, which meant
        # work landed under a personal address from anywhere else.
        #
        # mkDefault stays, so a host can still commit under another address.
        # The git identity below reads this value, so overriding it moves
        # both.
        user.email = lib.mkDefault "carl.andersson@dynamist.se";

        # jj does not read git's config for the committer identity. Checked
        # in a colocated repo: a [user] section written straight into
        # .git/config changed nothing, and jj stamped its own value on the
        # commit. So this scope is the only thing that moves the address for
        # a single repo, and the git block below is for git's benefit alone.
        "--scope" = [
          (
            {
              "--when".repositories = personalRepos;
              user.email = personalEmail;
            }
            // lib.optionalAttrs signing { signing.key = pgp.personal; }
          )
        ];
        git.private-commits = "description(glob:'private:*')";
        ui.pager = [
          "sh"
          "-c"
          "exec \${PAGER:-less -FRX}"
        ];
        merge-tools.jj-hunk = {
          program = "jj-hunk";
          edit-args = [
            "select"
            "$left"
            "$right"
          ];
        };
      }
      // lib.optionalAttrs signing {
        # `own` signs the commits this user authors and leaves everybody
        # else's signatures alone. `force` would re-sign a commit written by
        # someone else, which is a claim this configuration should not make.
        #
        # jj rewrites a commit far more often than git does -- every snapshot
        # of the working copy is a rewrite -- so this runs gpg often. That is
        # cheap with the agent holding the passphrase and impossible without
        # it. `jj --config signing.behavior=drop` is the way past it when the
        # agent is cold and the work is not worth a prompt.
        signing = {
          backend = "gpg";
          behavior = "own";
          key = pgp.work;
        };
      };
    };
    programs.jjui = {
      enable = true;
      settings = { };
    };
    xdg.configFile."jjui".source = config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/jjui";

    programs.git = {
      enable = true;
      ignores = [
        "CLAUDE.local.md"
        "**/.claude/settings.local.json"
      ];
      settings = {
        # `//` is shallow, so `signingKey` is merged into `user` here rather
        # than added as `user.signingKey` beside this block. Written the other
        # way it replaces the whole `user` attribute and silently takes the
        # name and the address with it.
        user = {
          name = config.programs.jujutsu.settings.user.name;
          email = config.programs.jujutsu.settings.user.email;
        }
        // lib.optionalAttrs signing { signingKey = pgp.work; };
      }
      // lib.optionalAttrs signing {
        # `openpgp` is already git's default, and it is stated because the
        # value is a global that any other config file can move. A machine
        # where something set `gpg.format = ssh` would otherwise read this
        # fingerprint as a path to an ssh key and fail in a way that does not
        # name the cause.
        gpg.format = "openpgp";
        commit.gpgSign = true;
        tag.gpgSign = true;
      };

      # The same exception, for git's own sake. Nothing here uses git to
      # commit, but the address it would use should not be the work one
      # either. gitdir: needs the trailing slash to match a directory.
      includes = map (repo: {
        condition = "gitdir:${repo}/";
        contents.user = {
          email = personalEmail;
        }
        // lib.optionalAttrs signing { signingKey = pgp.personal; };
      }) personalRepos;
    };
  };
}
