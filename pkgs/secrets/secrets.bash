# secrets: croshome's front end to sops.
#
#   secrets unlock            decrypt ../secrets/identity.age into the kernel keyring
#   secrets lock              drop it from the keyring
#   secrets status            JSON: keyring state, TPM identity, repository
#   secrets edit FILE         sops FILE, FILE relative to secrets/sops
#   secrets set FILE KEY      value from stdin, no editor
#   secrets get FILE KEY      print one value
#   secrets create FILE       new file from plaintext YAML on stdin; no unlock
#   secrets sync             regenerate .sops.yaml, re-encrypt every file to it
#   secrets tpm-enroll        make a TPM-held admin identity on this machine
#   secrets key               SOPS_AGE_KEY_CMD: print the master identity
#
# KEY is a dotted path: `aid.deepseek` is ["aid"]["deepseek"].

keyname=croshome-age
tpm_identity=${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/tpm.txt

die() {
  echo "secrets: $*" >&2
  exit 1
}

repo() {
  local d=$PWD
  while [ "$d" != / ]; do
    [ -f "$d/secrets/sops/keys.nix" ] && {
      echo "$d"
      return
    }
    d=$(dirname "$d")
  done
  d=${CROSHOME:-$HOME/Code/croshome}
  [ -f "$d/secrets/sops/keys.nix" ] || die "no croshome checkout above $PWD or at $d; set CROSHOME"
  echo "$d"
}

master_pubkey() {
  sed -n 's/^ *lillecarl = "\(age1[^"]*\)".*/\1/p' "$(repo)/secrets/sops/keys.nix"
}

key_id() {
  keyctl search @u user "$keyname" 2>/dev/null
}

# A login shell's session keyring does not link @u, so a key added from it is
# not possessed there and only gets the default user perm, view: unreadable,
# and setperm is refused. Linking @u into a throwaway session gives
# possession for the setperm. User then gets view, read, search: any process
# of this uid reads it, from any session or a systemd user unit.
store() {
  keyctl session - sh -c "keyctl link @u @s && keyctl setperm \"\$(keyctl padd user $keyname @u)\" 0x3f0b0000" >/dev/null ||
    die "could not store the key in the keyring"
}

unlock() {
  [ -n "$(key_id)" ] && return 0
  if ! { : </dev/tty; } 2>/dev/null; then
    die "locked, and no terminal to ask for the passphrase. Run 'secrets unlock' in a terminal."
  fi
  local identity
  identity="$(repo)/secrets/identity.age"
  echo "secrets: decrypting $identity (scrypt, takes a few seconds)" >&2
  age --decrypt "$identity" | grep '^AGE-SECRET-KEY-' | store
  [ -n "$(key_id)" ] || die "decryption gave no key"
}

cmd_key() {
  # sops calls this once per recipient stanza. Answer only for the master, so
  # a stanza that a TPM identity opens never triggers a passphrase prompt.
  if [ -n "${SOPS_AGE_RECIPIENT:-}" ] && [ "$SOPS_AGE_RECIPIENT" != "$(master_pubkey)" ]; then
    return 0
  fi
  unlock
  keyctl pipe "$(key_id)"
}

# Unlock before sops runs: sops swallows the key command's stderr, so a
# locked keyring would surface only as "no master key was able to decrypt".
with_sops() {
  export SOPS_AGE_KEY_CMD="$0 key"
  if [ -f "$tpm_identity" ]; then
    export SOPS_AGE_KEY_FILE="$tpm_identity"
  else
    unlock
  fi
  cd "$(repo)/secrets/sops"
  sops "$@"
}

# a.b.c -> ["a"]["b"]["c"]
index() {
  local out="" part
  IFS=. read -ra parts <<<"$1"
  for part in "${parts[@]}"; do out+="[\"$part\"]"; done
  echo "$out"
}

cmd_sync() {
  local root
  root=$(repo)
  nix eval --impure --json --expr \
    "import $root/secrets/sops/sops-yaml.nix { lib = (import <nixpkgs/lib>); }" |
    jq . >"$root/secrets/sops/.sops.yaml"
  echo "wrote $root/secrets/sops/.sops.yaml" >&2
  local f
  while IFS= read -r f; do
    with_sops updatekeys --yes "$f" >&2
  done < <(cd "$root/secrets/sops" && find . -name '*.yaml' ! -name .sops.yaml | sort)
}

cmd_status() {
  local unlocked=false tpm=null
  [ -n "$(key_id)" ] && unlocked=true
  [ -f "$tpm_identity" ] && tpm=$(age-plugin-tpm -y "$tpm_identity" | jq -R .)
  jq -n --arg repo "$(repo)" --argjson unlocked "$unlocked" --argjson tpm "$tpm" \
    '{repo: $repo, unlocked: $unlocked, tpm_recipient: $tpm}'
}

cmd_tpm_enroll() {
  [ -f "$tpm_identity" ] && die "$tpm_identity exists"
  [ -e /dev/tpmrm0 ] || die "no /dev/tpmrm0 on this machine"
  install -d -m 700 "$(dirname "$tpm_identity")"
  age-plugin-tpm --generate -o "$tpm_identity"
  chmod 600 "$tpm_identity"
  echo "add this to admins in secrets/sops/keys.nix, then run 'secrets sync':" >&2
  age-plugin-tpm -y "$tpm_identity"
}

case "${1:-}" in
key) cmd_key ;;
unlock) unlock ;;
lock)
  id=$(key_id)
  [ -n "$id" ] && keyctl unlink "$id" @u >/dev/null
  ;;
status) cmd_status ;;
edit)
  [ $# -eq 2 ] || die "usage: secrets edit FILE"
  with_sops edit "$2"
  ;;
set)
  [ $# -eq 3 ] || die "usage: secrets set FILE KEY < value"
  [ -t 0 ] && die "the value comes from stdin"
  # --value-stdin wants JSON; -Rs makes the raw bytes one JSON string.
  jq -Rs . | with_sops set --value-stdin "$2" "$(index "$3")"
  ;;
get)
  [ $# -eq 3 ] || die "usage: secrets get FILE KEY"
  with_sops decrypt --extract "$(index "$3")" "$2"
  ;;
create)
  # Public keys only, so no unlock: an agent can write a whole new file.
  [ $# -eq 2 ] || die "usage: secrets create FILE < plaintext.yaml"
  [ -t 0 ] && die "the plaintext comes from stdin"
  cd "$(repo)/secrets/sops"
  [ -e "$2" ] && die "$2 exists; use set or edit"
  mkdir -p "$(dirname "$2")"
  sops encrypt --filename-override "$2" /dev/stdin >"$2.tmp"
  mv "$2.tmp" "$2"
  ;;
sync) cmd_sync ;;
tpm-enroll) cmd_tpm_enroll ;;
sops)
  shift
  with_sops "$@"
  ;;
-h | --help | "")
  cat <<'EOF'
secrets unlock | lock | status | edit FILE | set FILE KEY <value | get FILE KEY
        | create FILE <plain.yaml | sync | tpm-enroll | key | sops ARGS...
FILE is relative to secrets/sops; KEY is dotted (aid.deepseek).
EOF
  ;;
*) die "unknown command '$1'; see --help" ;;
esac
