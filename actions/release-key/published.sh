#!/usr/bin/env bash
# What keyserver.ubuntu.com (HKP) and keys.openpgp.org (VKS) publish for the first primary of
# <certificate>, each written into <directory>, as the release gate reads them: an answer that holds
# nothing for it leaves nothing, and one that is no answer refuses. What a file holds is the caller's
# to judge; merged by --import-options merge-only it adds only what that primary signed. The bases
# default to the two the organisation publishes to. Exit 0 when both answered; 75 when one did not.
# Usage: published.sh <certificate> <directory> [<hkp base> <vks base>]
set -euo pipefail

[[ $# -eq 2 || $# -eq 4 ]] || {
  printf 'usage: published.sh <certificate> <directory> [<hkp base> <vks base>]\n' >&2
  exit 64
}
certificate=$1 directory=$2
hkp=${3:-https://keyserver.ubuntu.com}
vks=${4:-https://keys.openpgp.org}
for tool in gpg gpgconf curl awk mktemp; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '%s not found\n' "${tool}" >&2
    exit 69
  }
done
home=$(mktemp -d)
readonly home
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
  gpgconf --homedir "${home}" --kill all 2>/dev/null || true # its agent may never start
  rm -rf "${home}"
}
trap cleanup EXIT
fingerprint=$(gpg --homedir "${home}" --batch --with-colons --show-keys "${certificate}" | awk -F: '$1 == "fpr" {print $10; exit}')
[[ ${fingerprint} =~ ^[0-9A-F]{40}$ ]] || {
  printf 'no v4 primary in %s\n' "${certificate}" >&2
  exit 65
}
fetch() { # label, URL
  local code
  code=$(curl --silent --show-error --location --max-time 60 --output "${directory}/$1" --write-out '%{http_code}' "$2") || code=000
  case ${code} in
    200) ;;
    404) rm -f -- "${directory:?}/$1" ;;
    *)
      rm -f -- "${directory:?}/$1"
      printf '%s did not answer for %s (HTTP %s)\n' "$2" "${fingerprint}" "${code}" >&2
      exit 75
      ;;
  esac
}
fetch hkp.asc "${hkp%/}/pks/lookup?op=get&options=mr&search=0x${fingerprint}"
fetch vks.asc "${vks%/}/vks/v1/by-fingerprint/${fingerprint}"
kept=("${directory}"/*.asc)
[[ -e ${kept[0]} ]] || kept=()
printf 'published for %s: %d files\n' "${fingerprint}" "${#kept[@]}"
