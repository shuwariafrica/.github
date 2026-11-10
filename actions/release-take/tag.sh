#!/usr/bin/env bash
# Verifies a release tag as the release gate verifies its own. <payload> is the tag object's bytes
# before its signature, and must open by naming <commit> as its object, a commit as its type and
# <tag> as its name; <signature> must be one signature over it, under gpg and under sqv, by an
# admitted primary or one of its subkeys, neither revoked nor expired now. The admitted primaries are
# those of <certificates>/*.asc, merged with every file under <published> by --import-options
# merge-only, which can add only what such a primary itself signed (a revocation, a renewal) and no
# key beside them.
# Usage: tag.sh <certificates directory> <published directory> <tag> <commit> <payload> <signature>
# Exit 0 when gpg and sqv both verify; 64 for usage; 65 when a certificate or a published file does
# not import, or the payload names another object; 69 for an absent tool; 70 when the signature does
# not verify.
set -euo pipefail

[[ $# -eq 6 ]] || {
  printf 'usage: tag.sh <certificates directory> <published directory> <tag> <commit> <payload> <signature>\n' >&2
  exit 64
}
certificates=$1 published=$2 tag=$3 commit=$4 payload=$5 signature=$6
for tool in gpg gpgconf sqv awk grep sort find mktemp; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '%s not found\n' "${tool}" >&2
    exit 69
  }
done
work=$(mktemp -d)
readonly work
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
  gpgconf --homedir "${work}/home" --kill all 2>/dev/null || true # its agent may never start
  rm -rf "${work}"
}
trap cleanup EXIT
mkdir -m 700 "${work}/home"
primaries() { # each primary's fingerprint in the verifying home, sorted
  gpg --homedir "${work}/home" --batch --with-colons --list-keys |
    awk -F: '$1 == "pub" {want = 1; next} $1 == "fpr" && want {print $10; want = 0}' | sort
}

opening=$(head -n 3 -- "${payload}")
mapfile -t header <<<"${opening}"
[[ ${#header[@]} -eq 3 && ${header[0]} == "object ${commit}" && ${header[1]} == 'type commit' && ${header[2]} == "tag ${tag}" ]] || {
  printf 'the signed tag object does not name commit %s as tag %s\n' "${commit}" "${tag}" >&2
  exit 65
}

find "${certificates}" -maxdepth 1 -type f -name '*.asc' -print0 >"${work}/certificates"
mapfile -d '' -t files <"${work}/certificates"
((${#files[@]} > 0)) || {
  printf 'no certificate under %s\n' "${certificates}" >&2
  exit 65
}
for file in "${files[@]}"; do
  gpg --homedir "${work}/home" --batch --quiet --import "${file}" 2>/dev/null || {
    printf 'an admitted certificate does not import: %s\n' "${file}" >&2
    exit 65
  }
done
admitted=$(primaries)
find "${published}" -type f -print0 >"${work}/published"
mapfile -d '' -t files <"${work}/published"
for file in "${files[@]}"; do
  gpg --homedir "${work}/home" --batch --quiet --import-options merge-only --import "${file}" 2>/dev/null || {
    printf 'what a keyserver published for an admitted primary does not import: %s\n' "${file}" >&2
    exit 65
  }
done
merged=$(primaries)
[[ -n ${admitted} && ${merged} == "${admitted}" ]] || {
  printf 'a published file added a key beside the admitted primaries\n' >&2
  exit 65
}
gpg --homedir "${work}/home" --batch --export >"${work}/keyring.pgp"

# A signature gpg refuses is reported below, with this script's own status.
status=$(gpg --homedir "${work}/home" --batch --status-fd 1 --verify "${signature}" "${payload}" 2>/dev/null) || true
signatures=$(grep -c '^\[GNUPG:\] NEWSIG' <<<"${status}" || true)
primary=$(awk '$2 == "VALIDSIG" {print $NF; exit}' <<<"${status}")
if [[ ${signatures} != 1 || -z ${primary} ]] || ! grep -q '^\[GNUPG:\] GOODSIG ' <<<"${status}" ||
  grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG) ' <<<"${status}" || ! grep -qxF -- "${primary}" <<<"${admitted}"; then
  printf 'gpg does not verify the tag %s as one signature by an admitted key, unrevoked and unexpired\n' "${tag}" >&2
  exit 70
fi
sqv --keyring "${work}/keyring.pgp" "${signature}" "${payload}" >/dev/null || {
  printf 'sqv does not verify the tag %s\n' "${tag}" >&2
  exit 70
}
printf 'tag %s: commit %s, signed by %s\n' "${tag}" "${commit}" "${primary}"
