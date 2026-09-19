# The `sieve` command, which manages the incoming mail rules for the Migadu
# mailbox that ./mail.nix configures.
#
# The rules live in ./sieve/postspace.sieve, in this checkout. `sieve push`
# uploads that file to the server and makes it the active script. So the
# repository is the source of truth and the server holds a copy.
#
# Three facts about Migadu's ManageSieve proxy decide this shape. All three
# were measured against the live account:
#
#   * It offers no `include`. One script holds every rule.
#   * Only one script is active. Activating ours deactivates the webmail's.
#   * `CHECKSCRIPT` validates a script and stores nothing. It reports the
#     line and the column of an error, and it rejects an extension the
#     server does not have. It is free, so `push` always runs it first.
#
# The webmail writes its own script, `rainloop.user`, and activates it on
# every save. That script stays on the server, inactive, as a way back.
# Never delete it. Never edit filters in the webmail: a save there makes
# `rainloop.user` active again and the rules in this repository stop
# running, with nothing to report it. `sieve list` shows which one is
# active.
#
# The file is read at run time, not at build time. An edit to the rules
# therefore needs no rebuild, which is what makes the check-diff-push loop
# usable. A rebuild is only needed to change this file.
{
  config,
  pkgs,
  selfStr,
  ...
}:
let
  account = config.accounts.email.accounts.postspace;

  # ManageSieve. Not an option of the home-manager mail account, which
  # describes IMAP and SMTP only, so it is stated here.
  port = 4190;

  # The name our script takes on the server. Anything but `rainloop.user`,
  # which belongs to the webmail.
  remoteName = "croshome";

  sieve = pkgs.writeShellApplication {
    name = "sieve";
    runtimeInputs = [
      pkgs.sieve-connect
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gnused
    ];
    text = ''
      server=${account.imap.host}
      port=${toString port}
      user=${account.userName}
      remote=${remoteName}
      passfile=${config.age.secrets.migadu-pass.path}
      file="''${SIEVE_FILE:-${selfStr}/home/sieve/postspace.sieve}"

      usage() {
        cat <<'EOF'
      sieve -- the incoming mail rules for this Migadu mailbox

        sieve list          what scripts the server holds, and which is active
        sieve check [FILE]  ask the server to validate FILE; stores nothing
        sieve diff [FILE]   the active remote script against FILE
        sieve pull [OUT]    write the active remote script to OUT, or to stdout
        sieve push [FILE]   check FILE, show the diff, then upload and activate

      FILE defaults to $SIEVE_FILE, and then to the rules in the checkout.
      `diff` exits 1 when the two differ. `push` needs --yes with no terminal.
      EOF
      }

      if [ ! -r "$passfile" ]; then
        echo "sieve: cannot read $passfile" >&2
        echo "sieve: home agenix writes it at activation -- run ai-rebuild" >&2
        exit 1
      fi

      work="$(mktemp -d)"
      trap 'rm -rf "$work"' EXIT

      sc() {
        sieve-connect --server "$server" --port "$port" --user "$user" \
          --passwordfd 3 "$@" 3<"$passfile"
      }

      # `sieve-connect --list` prints one script per line and marks at most
      # one ACTIVE. It quotes a name that needs it, so accept both forms.
      active_script() {
        sc --list | sed -n -e 's/^"\(.*\)" ACTIVE$/\1/p' -e 's/^\([^"].*\) ACTIVE$/\1/p'
      }

      fetch_active() {
        local current
        current="$(active_script)"
        if [ -z "$current" ]; then
          return 1
        fi
        sc --download --remotesieve "$current" --localsieve "$work/remote.sieve"
        printf '%s\n' "$current"
      }

      cmd_diff() {
        local target="$1" current rc=0
        if ! current="$(fetch_active)"; then
          echo "sieve: the server has no active script" >&2
          current="none"
          : > "$work/remote.sieve"
        fi
        diff --unified --label "server: $current" --label "$target" \
          "$work/remote.sieve" "$target" || rc=$?
        return "$rc"
      }

      cmd_push() {
        local target="$1" confirmed="$2" current reply
        sc --checkscript --localsieve "$target"
        echo "sieve: the server accepts $target" >&2

        cmd_diff "$target" || true

        current="$(active_script)"
        if [ -n "$current" ] && [ "$current" != "$remote" ]; then
          echo "sieve: \"$current\" is active now, and this deactivates it" >&2
        fi

        if [ "$confirmed" != yes ]; then
          if [ ! -t 0 ]; then
            echo "sieve: refusing to push with no terminal -- pass --yes" >&2
            exit 1
          fi
          printf 'sieve: upload %s as "%s" and activate it? [y/N] ' \
            "$target" "$remote" >&2
          read -r reply
          case "$reply" in
            y | Y | yes) ;;
            *)
              echo "sieve: nothing sent" >&2
              exit 1
              ;;
          esac
        fi

        sc --upload --localsieve "$target" --remotesieve "$remote"
        sc --activate --remotesieve "$remote"
        echo "sieve: \"$remote\" is the active script" >&2
      }

      cmd_pull() {
        local out="$1" current
        if ! current="$(fetch_active)"; then
          echo "sieve: the server has no active script" >&2
          exit 1
        fi
        if [ -n "$out" ]; then
          cp "$work/remote.sieve" "$out"
          echo "sieve: wrote $out from \"$current\"" >&2
        else
          cat "$work/remote.sieve"
        fi
      }

      confirmed=no
      args=()
      for arg in "$@"; do
        case "$arg" in
          --yes) confirmed=yes ;;
          *) args+=("$arg") ;;
        esac
      done
      set -- ''${args[@]+"''${args[@]}"}

      case "''${1:-}" in
        list) sc --list ;;
        check) sc --checkscript --localsieve "''${2:-$file}" ;;
        diff) cmd_diff "''${2:-$file}" ;;
        pull) cmd_pull "''${2:-}" ;;
        push) cmd_push "''${2:-$file}" "$confirmed" ;;
        "" | -h | --help | help) usage ;;
        *)
          echo "sieve: no such command: $1" >&2
          usage >&2
          exit 1
          ;;
      esac
    '';
  };
in
{
  home.packages = [ sieve ];
}
