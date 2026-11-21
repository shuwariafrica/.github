#!/usr/bin/env bash
# The release gate holds a .github action in a credential job by its commit alone and reads nothing
# inside it, so this case holds what those composites run: every action a crate-*, release-key or
# key-vault composite uses (each action.yml under them, at any depth) is shuwariafrica/.github's own
# at a full commit, or listed in actions/third-party.tsv at the commit used. A local (./) or
# docker:// action is neither.
# Usage: run.sh [--tree <directory>]   --tree a tree holding actions/; this repository's by default.
# Prints each composite's actions as ok or FAIL and the counts. Exit 0 when every one is held; 1
# when one is not; 64 for usage; 69 for an absent tool.
# Needs yq (mikefarah's) and awk.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tree=$(cd -- "${here}/../.." && pwd)
case ${1:-} in
  --tree)
    tree=$(cd -- "$2" && pwd)
    ;;
  '') ;;
  *)
    printf 'usage: run.sh [--tree <directory>]\n' >&2
    exit 64
    ;;
esac
for tool in yq awk find; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '%s not found\n' "${tool}" >&2
    exit 69
  }
done

list=${tree}/actions/third-party.tsv
passed=0 failed=0
found=$(find "${tree}"/actions/crate-* "${tree}/actions/release-key" "${tree}/actions/key-vault" -name action.yml -o -name action.yaml)
found=$(LC_ALL=C sort <<<"${found}")
mapfile -t files <<<"${found}"
[[ -n ${found} ]] || files=()
((${#files[@]} > 0)) || {
  printf 'no composite found under %s/actions\n' "${tree}" >&2
  exit 1
}
for file in "${files[@]}"; do
  listed=$(yq -r '[explode(.) | .. | select(tag == "!!map" and has("uses")) | .uses] | .[]' "${file}")
  held=yes
  while IFS= read -r uses; do
    [[ -n ${uses} ]] || continue
    target=${uses%@*} ref=${uses##*@}
    [[ ${uses} == *@* ]] || ref=''
    named=$(cut -d/ -f1-2 <<<"${target}")
    if [[ ${named,,} == shuwariafrica/.github ]]; then
      [[ ${ref} =~ ^[0-9a-f]{40}$ ]] && continue
    elif awk -F'\t' -v t="${target,,}" -v r="${ref}" 'tolower($1) == t && $2 == r {found = 1} END {exit !found}' "${list}"; then
      continue
    fi
    printf '    %s uses %s, neither .github'"'"'s own at a commit nor listed at its commit\n' "${file#"${tree}/"}" "${uses}" >&2
    held=no
  done <<<"${listed}"
  if [[ ${held} == yes ]]; then
    printf 'ok    %s\n' "${file#"${tree}/"}"
    passed=$((passed + 1))
  else
    printf 'FAIL  %s\n' "${file#"${tree}/"}"
    failed=$((failed + 1))
  fi
done
printf '%d passed, %d failed\n' "${passed}" "${failed}"
((failed == 0))
