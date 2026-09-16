#! /usr/bin/env bash
# What can the other accounts on this machine read? Colleagues hold
# unprivileged accounts here (see ./dynusers.nix). They are trusted, and
# still should not be reading keys, tokens or histories. Exits 1 on any
# finding, so a timer can nag later if one ever runs it.
#
# The scans, in order:
#
#   1. The home directories themselves: other-readable, other-traversable,
#      or shared-group readable. 0700 is the shape that keeps everything
#      under a home out of reach; the scans below then only matter for
#      homes that are open.
#   2. Sensitive files other users can reach, by name and directory. A
#      file whose bits say readable but whose ancestor directories lock
#      the path is reported as latent, not as a finding: nothing is
#      reachable through it today, and the line is there so a future
#      chmod of a home directory does not silently turn it into a leak.
#   3. Reachable files whose CONTENT looks like a secret.
#   4. Files other users can write -- worse than a read, always a finding.
#   5. The repository: tracked files checked for secret-shaped content,
#      every .age file checked to really be ciphertext.
#
# Find history is not scanned: this repository is public, and a scan that
# walks every historical blob is a different tool.

set -u -o pipefail

home_root=/home
repo=${1:-/home/lillecarl/Code/croshome}
findings=0

note() { printf '%s\n' "$*"; }
bad() {
  findings=$((findings + 1))
  printf '  FINDING: %s\n' "$*"
}

# Checkouts, stores and build trees: unreadably large, and the repository
# scan covers the checkout that matters.
prune='( -name .git -o -name .jj -o -name node_modules -o -name .cache -o -name .npm -o -name .cargo -o -name .rustup -o -name target -o -name .nix-defexpr -o -name result )'

secret_shapes='BEGIN [A-Z ]*PRIVATE KEY|AGE-SECRET-KEY-[A-Z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|xox[abp]-[A-Za-z0-9-]{10,}'

# Latent lines pile up by the thousand when a cache directory defaults to
# group-write, so they are counted and shown five at a time. Findings are
# always printed in full.
latent_buf=
latent() { latent_buf="$latent_buf$1"$'\n'; }
show_latent() {
  local total
  total=$(printf '%s' "$latent_buf" | grep -c . || true)
  if [ "$total" -gt 0 ]; then
    printf '%s' "$latent_buf" | grep . | head -5 | sed 's/^/  latent:  /'
    [ "$total" -gt 5 ] && printf '  latent:  +%s more\n' "$((total - 5))"
  fi
  latent_buf=
}

# Can an account outside the owner's session reach this path at all?
# stat(1) prints the ten-symbol mode; positions are 0 type, 1-3 user,
# 4-6 group, 7-9 other. Reaching a known path needs search (x) on every
# directory above it; listing needs r as well, which section 1 covers.
others_can_reach() {
  local p=$1 bits group
  while [ "$p" != / ] && [ "$p" != . ]; do
    bits=$(stat -c %A "$p" 2>/dev/null) || return 1
    group=$(stat -c %G "$p" 2>/dev/null)
    if [ "${bits:9:1}" != x ] && { [ "${bits:6:1}" != x ] || [ "$group" != users ]; }; then
      return 1
    fi
    p=$(dirname "$p")
  done
  return 0
}

note "== 1. home directories =="
for d in "$home_root"/*; do
  [ -d "$d" ] || continue
  perms=$(stat -c '%A %G' "$d")
  bits=${perms%% *}
  group=${perms#* }
  other_r=${bits:7:1}
  group_r=${bits:4:1}
  if [ "$other_r" = r ] || [ "$group_r" = r ] && [ "$group" = users ]; then
    bad "$d is mode $bits -- others can list it (want 0700)"
  fi
done
if [ "$findings" -eq 0 ]; then
  note "  every home is closed to others"
fi

note "== 2. sensitive files reachable by others =="
# The predicates are deliberate word lists, so the unquoted expansion below
# is the point, not a bug.
# shellcheck disable=SC2086
sensitive=$(find "$home_root" -xdev \
    $prune -prune -o \
    -type f \
    \( -perm -o=r -o \( -perm -g=r -group users \) \) \
    \( -iname 'id_rsa*' -o -iname 'id_ecdsa*' -o -iname 'id_ed25519*' -o -iname 'id_dsa*' \
       -o -iname '*.pem' -o -iname '*.key' -o -iname '*.age' \
       -o -name '.git-credentials' -o -name '.netrc' \
       -o -iname '.env' -o -iname '.env.*' \
       -o -iname '*token*' -o -iname '*password*' -o -iname '*credential*' \
       -o -path '*/.ssh/*' -o -path '*/.gnupg/*' -o -path '*/.kube/*' \
       -o -path '*/.docker/*' \
       -o -path '*/.config/gh/*' -o -path '*/.config/cachix/*' \
       -o -path '*/.config/opencode/*' -o -path '*/.config/codex/*' \
       -o -path '*/.claude/*' -o -path '*/.gemini/*' \
    \) \
    -print 2>/dev/null)
if [ -n "$sensitive" ]; then
  while IFS= read -r f; do
    case "$f" in
      *authorized_keys | *.pub | *known_hosts) continue ;;
    esac
    if others_can_reach "$f"; then
      bad "readable by others: $f"
    else
      latent "bits say readable, the path does not: $f"
    fi
  done <<< "$sensitive"
else
  note "  none"
fi
show_latent

note "== 3. reachable files whose content looks like a secret =="
# shellcheck disable=SC2086
hits=$(find "$home_root" -xdev \
    $prune -prune -o \
    -type f -size -1M \
    \( -perm -o=r -o \( -perm -g=r -group users \) \) \
    -exec grep -lIE "$secret_shapes" {} + 2>/dev/null)
if [ -n "$hits" ]; then
  while IFS= read -r f; do
    if others_can_reach "$f"; then
      bad "secret-shaped content readable by others: $f"
    else
      latent "secret-shaped content, behind a closed path: $f"
    fi
  done <<< "$hits"
else
  note "  none"
fi

note "== 4. files other users can write =="
# shellcheck disable=SC2086
wr=$(find "$home_root" -xdev \
    $prune -prune -o \
    -type f \
    \( -perm -o=w -o \( -perm -g=w -group users \) \) \
    -print 2>/dev/null)
if [ -n "$wr" ]; then
  while IFS= read -r f; do
    if others_can_reach "$f"; then
      bad "writable by others: $f"
    else
      latent "writable if the path ever opens: $f"
    fi
  done <<< "$wr"
else
  note "  none"
fi
show_latent

note "== 5. repository: $repo =="
if [ ! -d "$repo/.jj" ] && [ ! -d "$repo/.git" ]; then
  bad "no repository at $repo"
elif files=$(cd "$repo" && jj --no-pager file list -r @ 2>/dev/null); then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base=$(basename "$f")
    case "$f" in
      *.age)
        header=$(head -c 40 "$repo/$f" 2>/dev/null)
        case "$header" in
          -----BEGIN* | age-encryption.org*) ;;
          *) bad "tracked .age file is not ciphertext: $f" ;;
        esac
        continue
        ;;
    esac
    case "$base" in
      # The rules file is public by design; its name is the match.
      secrets.nix) continue ;;
      *.key | *.pem | *.env | *.token | *secret*)
        bad "tracked file looks like a plaintext secret: $f"
        ;;
    esac
  done <<< "$files"
  content=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 --no-run-if-empty -I{} grep -lIE "$secret_shapes" "$repo/{}" 2>/dev/null)
  if [ -n "$content" ]; then
    while IFS= read -r f; do
      bad "tracked file carries secret-shaped content: ${f#"$repo/"}"
    done <<< "$content"
  else
    note "  tracked files carry no secret-shaped content"
  fi
else
  note "  could not list tracked files; skipping"
fi

note
if [ "$findings" -gt 0 ]; then
  note "$findings finding(s)"
  exit 1
fi
note "clean"
