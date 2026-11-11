#!/usr/bin/env bash
# Verifies a release tag as the release gate verifies its own. <payload> is the tag object's bytes
# before its signature, and must open by naming <commit> as its object, a commit as its type and
# <tag> as its name; <signature> must be one signature over it, under gpg and under sqv, by an
# admitted primary or one of its subkeys, neither revoked nor expired now. The admitted primaries are
# those of <certificates>/*.asc, one to a file, as the commit holds them. Every file under <published>
# is merged into them by --import-options merge-only, which adds whatever such a primary itself signed
# and no key beside them; anything the merge changes other than a revocation is refused, so a
# keyserver can withdraw an admitted key and never extend one: no later subkey, renewal or user id.
# Usage: tag.sh <certificates directory> <published directory> <tag> <commit> <payload> <signature>
# Exit 0 when gpg and sqv both verify; 64 for usage; 65 when a certificate file is not one primary or
# does not import, a published file does not import or changes more than a revocation, or the payload
# names another object; 69 for an absent tool; 70 when the signature does not verify.
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
mkdir -m 700 "${work}/home" "${work}/show"
primaries() { # each primary's fingerprint in the verifying home, sorted
  gpg --homedir "${work}/home" --batch --with-colons --list-keys |
    awk -F: '$1 == "pub" {want = 1; next} $1 == "fpr" && want {print $10; want = 0}' | sort
}
# The verifying home's keys, user ids and their validity, one record a line. A primary's capability
# field also carries its usable subkeys' in upper case, which a subkey's revocation changes, so only
# its own are kept.
keys() {
  gpg --homedir "${work}/home" --batch --with-colons --list-keys |
    awk -F: -v OFS=: '$1 == "pub" { gsub(/[A-Z]/, "", $12) } $1 == "pub" || $1 == "sub" || $1 == "fpr" || $1 == "uid" { print }'
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
  # One primary a file: published.sh reads the revocations of a file's first primary alone.
  listed=$(gpg --homedir "${work}/show" --batch --with-colons --show-keys "${file}" 2>/dev/null) || listed=''
  count=$(grep -c '^pub:' <<<"${listed}" || true)
  [[ ${count} == 1 ]] || {
    printf 'an admitted certificate file holds %s primaries, not one: %s\n' "${count}" "${file}" >&2
    exit 65
  }
  gpg --homedir "${work}/home" --batch --quiet --import "${file}" 2>/dev/null || {
    printf 'an admitted certificate does not import: %s\n' "${file}" >&2
    exit 65
  }
done
admitted=$(primaries)
committed=$(keys)
find "${published}" -type f -print0 >"${work}/published"
mapfile -d '' -t files <"${work}/published"
for file in "${files[@]}"; do
  gpg --homedir "${work}/home" --batch --quiet --import-options merge-only --import "${file}" 2>/dev/null || {
    printf 'what a keyserver published for an admitted primary does not import: %s\n' "${file}" >&2
    exit 65
  }
done
merged=$(keys)
mapfile -t before <<<"${committed}"
mapfile -t after <<<"${merged}"
[[ -n ${admitted} && ${#before[@]} == "${#after[@]}" ]] || {
  printf 'what a keyserver published adds a key or user id to the admitted certificates\n' >&2
  exit 65
}
for index in "${!before[@]}"; do
  [[ ${before[index]} != "${after[index]}" ]] || continue
  IFS=: read -r -a was <<<"${before[index]}"
  IFS=: read -r -a now <<<"${after[index]}"
  # A revocation changes a record's validity, field 2, to r, and nothing else.
  [[ ${now[1]} == r ]] && was[1]=r
  [[ ${was[*]} == "${now[*]}" ]] || {
    printf 'what a keyserver published changes an admitted certificate other than by a revocation: %s\n' "${after[index]}" >&2
    exit 65
  }
done
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
