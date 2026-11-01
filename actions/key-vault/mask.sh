#!/usr/bin/env bash
# Registers every non-empty line of <file>, and every string within it when it is JSON, as a value
# the runner masks in the job's log (`::add-mask::`). Prints only the workflow commands, which the
# runner consumes and does not show.
# Usage: mask.sh <file>
set -euo pipefail

[[ $# -eq 1 ]] || {
  printf 'usage: mask.sh <file>\n' >&2
  exit 64
}
command -v jq >/dev/null 2>&1 || {
  printf 'jq not found\n' >&2
  exit 69
}
while IFS= read -r line || [[ -n ${line} ]]; do
  [[ -n ${line//[[:space:]]/} ]] && printf '::add-mask::%s\n' "${line}"
done <"$1"
if jq --exit-status 'type == "object" or type == "array"' "$1" >/dev/null 2>&1; then
  jq --raw-output '.. | strings | select(length > 0)' "$1" | while IFS= read -r value; do
    printf '::add-mask::%s\n' "${value}"
  done
fi
