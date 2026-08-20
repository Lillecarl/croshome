# Put the OpenPGP passphrase into gpg-agent, once, for both keys.
#
#   pgp-unlock             both keys
#   pgp-unlock work        one of them
#   pgp-unlock personal
#   pgp-unlock --status    what the agent holds
#   pgp-unlock --lock      forget it again
#
# Both keys share a passphrase, but gpg-agent caches per subkey, not per
# passphrase. So unlocking the work key leaves the personal one locked, and a
# commit in a repository that signs with the other key still stops to ask.
# This asks once and presets every subkey of both, which is the whole reason
# it exists.
#
# It must run in a terminal. It reads the passphrase itself rather than
# letting pinentry ask, because pinentry can only ask for one subkey at a
# time.
#
# `gpg-preset-passphrase` does not check what you type -- it puts the string
# in the cache and returns success either way. So this signs with each key
# afterwards to prove the cache is right, and empties it again if it is not. A
# wrong passphrase sitting in the agent is worse than an empty one: the next
# signature fails somewhere far from here.

usage() {
  # Spelled out rather than scraped from the header above. `writeShellApplication`
  # puts a shebang and its own `set -o` lines before this text, so walking the
  # file from line 1 finds those and stops.
  cat <<'USAGE'
Put the OpenPGP passphrase into gpg-agent, once, for both keys.

  pgp-unlock             both keys
  pgp-unlock work        one of them
  pgp-unlock personal
  pgp-unlock --status    what the agent holds
  pgp-unlock --lock      forget it again

Both keys share a passphrase, but gpg-agent caches per subkey. So unlocking
one leaves the other locked, and a commit in a repository that signs with the
other key still stops to ask. This asks once and presets every subkey of both.

It must run in a terminal, and it signs with each key afterwards to prove the
passphrase was right.
USAGE
}

# Every keygrip of a key, tagged with what that subkey can do. The `grp:` line
# belongs to the `sec:` or `ssb:` line above it, so the capability has to be
# carried down.
grips_of() {
  gpg --list-secret-keys --with-colons --with-keygrip "$1" 2>/dev/null |
    awk -F: '/^(sec|ssb):/ { cap = $12 } /^grp:/ { print cap ":" $10 }'
}

# Whether this key can sign right now with nobody typing anything. Asked by
# signing, not by reading the agent's cache flags.
#
# `gpg-connect-agent 'keyinfo --list'` looks like the answer and is not. It
# reported `-` for a key that then signed without a prompt -- gpg-agent holds
# the unprotected key itself, separate from the passphrase cache that flag
# describes. Measured on this machine, which is why the check moved here.
#
# `--pinentry-mode error` is what makes this a question rather than a prompt:
# gpg returns a failure instead of asking, so the probe is silent in a
# terminal as well as outside one.
unlocked() {
  printf 'x' | gpg --batch --pinentry-mode error \
    --local-user "$1" --sign --output /dev/null 2>/dev/null
}

on_this_machine() {
  gpg --list-secret-keys "$1" >/dev/null 2>&1
}

fpr_of() {
  case "$1" in
  work) printf '%s' "$WORK_FPR" ;;
  personal) printf '%s' "$PERSONAL_FPR" ;;
  esac
}

status() {
  local name fpr
  for name in work personal; do
    fpr=$(fpr_of "$name")
    if ! on_this_machine "$fpr"; then
      echo "$name: not on this machine -- run secrets/pgp-import"
    elif unlocked "$fpr"; then
      echo "$name: unlocked"
    else
      echo "$name: locked"
    fi
  done
}

case "${1:-both}" in
-h | --help)
  usage
  exit 0
  ;;
--status)
  status
  exit 0
  ;;
--lock)
  # Drops every cached passphrase the agent holds, this key's and any other.
  # There is no way to forget one item, so say so rather than imply otherwise.
  gpg-connect-agent reloadagent /bye >/dev/null
  echo "locked: gpg-agent forgot every cached passphrase"
  exit 0
  ;;
work) wanted=(work) ;;
personal) wanted=(personal) ;;
both) wanted=(work personal) ;;
*)
  usage
  exit 1
  ;;
esac

for name in "${wanted[@]}"; do
  if ! on_this_machine "$(fpr_of "$name")"; then
    echo "pgp-unlock: the $name key is not on this machine" >&2
    echo "pgp-unlock: run secrets/pgp-import first" >&2
    exit 1
  fi
done

# Nothing to do is worth saying, not worth a prompt.
todo=()
for name in "${wanted[@]}"; do
  if unlocked "$(fpr_of "$name")"; then
    echo "$name: already unlocked"
  else
    todo+=("$name")
  fi
done
if [ ${#todo[@]} -eq 0 ]; then
  exit 0
fi

if [ ! -t 0 ]; then
  echo "pgp-unlock: ${todo[*]} still locked, and unlocking needs a terminal" >&2
  exit 1
fi

read -r -s -p "OpenPGP passphrase: " pw
echo
if [ -z "$pw" ]; then
  echo "pgp-unlock: refusing an empty passphrase" >&2
  exit 1
fi

for name in "${todo[@]}"; do
  fpr=$(fpr_of "$name")
  # Every subkey, not only the signing one. The encryption subkey is what
  # `gpg -d` needs, and presetting it here costs nothing.
  while IFS= read -r entry; do
    printf '%s' "$pw" | "$PRESET_BIN" --preset "${entry#*:}"
  done < <(grips_of "$fpr")

  # Prove it, with the same probe. `gpg-preset-passphrase` does not check what
  # it is given, so without this a typo would sit in the agent and break the
  # next signature somewhere far from here.
  if unlocked "$fpr"; then
    echo "$name: unlocked"
  else
    gpg-connect-agent reloadagent /bye >/dev/null
    echo "pgp-unlock: that passphrase does not open the $name key" >&2
    echo "pgp-unlock: the cache is emptied again, nothing wrong is left in it" >&2
    exit 1
  fi
done

unset pw
