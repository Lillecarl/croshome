#!/usr/bin/env bash
# gc-old-generations: delete NixOS system generations older than the booted one.
#
# Usage: gc-old-generations [--yes]
#
# Numbers come from /nix/var/nix/profiles/system-N-link, compared against
# /run/booted-system. The booted generation and anything newer (a
# switched-but-not-rebooted current, for example) survive. Deleting a
# generation only unregisters its profile; paths become collectable but
# nothing is garbage-collected here.
set -euo pipefail

profile=/nix/var/nix/profiles/system
yes=0
if [[ "${1:-}" == "--yes" ]]; then
  yes=1
elif [[ -n "${1:-}" ]]; then
  echo "usage: $(basename "$0") [--yes]" >&2
  exit 2
fi

booted_store=$(readlink -f /run/booted-system)
booted_num=""
olds=()
for link in "$profile"-*-link; do
  [[ -L $link ]] || continue
  num=${link##"$profile"-}
  num=${num%-link}
  [[ $num =~ ^[0-9]+$ ]] || continue
  if [[ $(readlink -f "$link") == "$booted_store" ]]; then
    booted_num=$num
  else
    olds+=("$num")
  fi
done

[[ -n $booted_num ]] || {
  echo "cannot map /run/booted-system to a numbered generation" >&2
  exit 1
}

delete=()
for n in ${olds[@]+"${olds[@]}"}; do
  if ((n < booted_num)); then
    delete+=("$n")
  fi
done

if ((${#delete[@]} == 0)); then
  echo "nothing older than booted generation $booted_num"
  exit 0
fi

# Numeric order, oldest first, for a readable report.
delete=($(printf '%s\n' "${delete[@]}" | sort -n))

echo "booted generation: $booted_num"
echo "deleting ${#delete[@]} generation(s): ${delete[*]}"
if ((yes == 0)); then
  read -r -p "delete them? [y/N] " answer
  [[ $answer == [yY]* ]] || exit 0
fi
# Separate arguments: nix-env reads one generation per argv word, so a
# single joined "${delete[*]}" word deletes only the first number.
sudo nix-env -p "$profile" --delete-generations "${delete[@]}"
