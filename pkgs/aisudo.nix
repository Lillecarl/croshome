{ writeShellApplication, coreutils, gnugrep, gawk }:
writeShellApplication {
  name = "aisudo";
  runtimeInputs = [
    coreutils
    gnugrep
    gawk
  ];
  text = ''
    set -euo pipefail

    # Queue root. Under sudo, drain the queue of the user who filled it:
    # macOS sudo preserves HOME already, Linux sudo resets it, so resolve
    # through SUDO_USER explicitly on both instead of trusting HOME.
    queue_root() {
      if [ "$(id -u)" -eq 0 ] && [ -n "''${SUDO_USER:-}" ]; then
        user_home=""
        if command -v getent >/dev/null 2>&1; then
          user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        else
          user_home="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')"
        fi
        printf '%s\n' "$user_home/.local/share/aisudo"
      else
        printf '%s\n' "''${XDG_DATA_HOME:-''${HOME:-/root}/.local/share}/aisudo"
      fi
    }

    queue_dir() {
      printf '%s\n' "$(queue_root)/queue"
    }

    usage() {
      cat <<'EOF'
    aisudo: a queue for privileged commands. The agent enqueues, a human runs.

    The split exists because elevation needs a password and a terminal with
    the right entitlements (Full Disk Access, a GUI session), neither of
    which an agent session has.

      aisudo [-m REASON] [--] COMMAND...   enqueue a command (the default)
      aisudo queue [-m REASON] [--] ...    same, explicit
      aisudo list                          show pending entries
      aisudo run [--yes]                   run pending entries with confirmation
      aisudo drop ID...                    discard entries without running
      aisudo help                          this text

    run executes as whoever invokes it: plain `aisudo run` in Terminal.app
    for user-level commands that need Full Disk Access, `sudo aisudo run`
    for root. Entries stay queued on failure or refusal.
    EOF
    }

    cmd_enqueue() {
      reason=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -m | --reason)
            if [ "$#" -lt 2 ]; then
              echo "aisudo: -m needs a value" >&2
              exit 2
            fi
            reason="$2"
            shift 2
            ;;
          --)
            shift
            break
            ;;
          -*)
            echo "aisudo: unknown flag: $1" >&2
            exit 2
            ;;
          *)
            break
            ;;
        esac
      done
      if [ "$#" -eq 0 ]; then
        echo "usage: aisudo [-m REASON] [--] COMMAND..." >&2
        exit 2
      fi
      # List output shows one line per entry: flatten the reason.
      reason="''${reason//$'\n'/ }"
      dir="$(queue_dir)"
      mkdir -p "$dir"
      chmod 700 "$(queue_root)" "$dir"
      id="$(date +%Y%m%d%H%M%S)-$$"
      {
        printf '# reason: %s\n' "''${reason:-none}"
        printf '%s\n' "$*"
      } > "$dir/$id"
      chmod 600 "$dir/$id"
      echo "queued as $id"
    }

    # Prints "reason<TAB>first command line" for one queue file.
    entry_summary() {
      reason="none"
      first="(empty)"
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          '# reason: '*) reason="''${line#'# reason: '}" ;;
          '#'*) ;;
          *)
            if [ "$first" = "(empty)" ]; then
              first="$line"
            fi
            ;;
        esac
      done < "$1"
      printf '%s\t%s\n' "$reason" "$first"
    }

    cmd_list() {
      dir="$(queue_dir)"
      if [ ! -d "$dir" ]; then
        echo "queue empty"
        return 0
      fi
      empty=1
      for f in "$dir"/*; do
        [ -e "$f" ] || continue
        empty=0
        printf '%s\t%s\n' "$(basename "$f")" "$(entry_summary "$f")"
      done
      if [ "$empty" -eq 1 ]; then
        echo "queue empty"
      fi
    }

    cmd_run() {
      assume_yes=0
      for arg in "$@"; do
        if [ "$arg" = "--yes" ]; then
          assume_yes=1
        else
          echo "aisudo run: unknown flag: $arg" >&2
          exit 2
        fi
      done
      dir="$(queue_dir)"
      if [ ! -d "$dir" ]; then
        echo "queue empty"
        return 0
      fi
      if [ "$(id -u)" -eq 0 ]; then
        who="root"
      else
        who="$(id -un)"
      fi
      ran_any=0
      for f in "$dir"/*; do
        [ -e "$f" ] || continue
        ran_any=1
        id="$(basename "$f")"
        cmd="$(grep -v '^#' "$f" || true)"
        if [ -z "$cmd" ]; then
          echo "--- $id: no command, skipping"
          continue
        fi
        echo "--- $id (as $who)"
        printf '%s\n' "$cmd"
        if [ "$assume_yes" -eq 0 ]; then
          ans=""
          read -r -p "run? [y/N/q] " ans || ans=""
          case "$ans" in
            [yY] | [yY][eE][sS]) ;;
            [qQ]* | quit | exit)
              echo "stopping"
              return 0
              ;;
            *)
              echo "skipped $id"
              continue
              ;;
          esac
        fi
        if bash -c "$cmd"; then
          rm -f "$f"
          echo "done $id"
        else
          rc=$?
          echo "failed $id (exit $rc), kept in queue, stopping" >&2
          return "$rc"
        fi
      done
      if [ "$ran_any" -eq 0 ]; then
        echo "queue empty"
      fi
    }

    cmd_drop() {
      if [ "$#" -eq 0 ]; then
        echo "usage: aisudo drop ID..." >&2
        exit 2
      fi
      dir="$(queue_dir)"
      for id in "$@"; do
        case "$id" in
          *"/"* | *".."*)
            echo "aisudo drop: refusing $id" >&2
            exit 2
            ;;
        esac
        if [ -f "$dir/$id" ]; then
          rm -f "$dir/$id"
          echo "dropped $id"
        else
          echo "aisudo drop: no such entry: $id" >&2
          exit 1
        fi
      done
    }

    main() {
      if [ "$#" -eq 0 ]; then
        cmd_list
        return 0
      fi
      case "$1" in
        list)
          shift
          cmd_list "$@"
          ;;
        run)
          shift
          cmd_run "$@"
          ;;
        drop)
          shift
          cmd_drop "$@"
          ;;
        queue | add | enqueue)
          shift
          cmd_enqueue "$@"
          ;;
        help | -h | --help)
          usage
          ;;
        *)
          cmd_enqueue "$@"
          ;;
      esac
    }

    main "$@"
  '';
}
