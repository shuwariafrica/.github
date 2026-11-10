#!/usr/bin/env bash
# Verifies each <file>.asc as one signature by C1, under gpg (VALIDSIG naming C1's primary) and under
# sqv, carrying the notation repository-ref@shuwari.africa that names the repository and ref of the
# run whose release-key made it. Two forms:
#   verify.sh home <gnupghome> <subkey fingerprint> <notation> <file>...
#     against the public key of the home release-key imported, made by that subkey (GOODSIG): a
#     release job's proof of what it signed, before it publishes;
#   verify.sh certificate <certificate> <published directory> <notation> <file>...
#     against C1's certificate alone, merged with each file published.sh left in the directory,
#     whose import may add only what C1 itself signed (a revocation, a renewal); made by any of C1's
#     signing subkeys, one that has since lapsed (EXPKEYSIG) included, since sqv holds it to the time
#     of signing. A revoked key (REVKEYSIG) refuses.
# <notation> is <repository id>:<ref>, or - for a signature made without one (sbt-pgp's own).
# Exit 0 only when gpg and sqv both verify every signature; 65 when a published file does not import
# or the certificate is not one primary; 70 when a signature does not verify.
set -euo pipefail

readonly name=repository-ref@shuwari.africa
usage() {
  printf 'usage: verify.sh home <gnupghome> <subkey> <notation> <file>...\n' >&2
  printf '       verify.sh certificate <certificate> <published directory> <notation> <file>...\n' >&2
  exit 64
}
[[ $# -ge 5 ]] || usage
form=$1
case ${form} in
  home) home=$2 subkey=$3 ;;
  certificate) certificate=$2 published=$3 ;;
  *) usage ;;
esac
notation=$4
shift 4
for tool in gpg gpgconf sqv awk grep mktemp; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '%s not found\n' "${tool}" >&2
    exit 69
  }
done
work=$(mktemp -d)
readonly work
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
  gpgconf --homedir "${work}/verify" --kill all 2>/dev/null || true # its agent may never start
  rm -rf "${work}"
}
trap cleanup EXIT
mkdir -m 700 "${work}/verify"
primaries() { # gnupghome: each primary's fingerprint
  gpg --homedir "$1" --batch --with-colons --list-keys | awk -F: '$1 == "pub" {want = 1; next} $1 == "fpr" && want {print $10; want = 0}'
}

if [[ ${form} == home ]]; then
  primary=$(primaries "${home}" | head -n1)
  gpg --homedir "${home}" --batch --export "${primary}" >"${work}/public.pgp"
  gpg --homedir "${work}/verify" --batch --quiet --import "${work}/public.pgp" 2>/dev/null
else
  gpg --homedir "${work}/verify" --batch --quiet --import "${certificate}" 2>/dev/null
  listed=$(primaries "${work}/verify")
  mapfile -t found <<<"${listed}"
  [[ -n ${listed} ]] || found=()
  [[ ${#found[@]} -eq 1 ]] || {
    printf 'the certificate holds %d primaries, not C1 alone\n' "${#found[@]}" >&2
    exit 65
  }
  primary=${found[0]}
  for file in "${published}"/*; do
    [[ -f ${file} ]] || continue
    gpg --homedir "${work}/verify" --batch --quiet --import-options merge-only --import "${file}" 2>/dev/null || {
      printf 'what a keyserver published for %s does not import: %s\n' "${primary}" "${file}" >&2
      exit 65
    }
  done
  listed=$(primaries "${work}/verify")
  mapfile -t found <<<"${listed}"
  [[ -n ${listed} ]] || found=()
  [[ ${#found[@]} -eq 1 && ${found[0]} == "${primary}" ]] || {
    printf 'a published file added a key beside %s\n' "${primary}" >&2
    exit 65
  }
  gpg --homedir "${work}/verify" --batch --export "${primary}" >"${work}/public.pgp"
fi

# The value of the one notation <name> a status block carries, %XX unescaped.
notation_of() { # status
  awk -v want="${name}" '
    function unescape(s,   out, i, hex) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        if (substr(s, i, 1) == "%" && i + 2 <= length(s)) {
          hex = toupper(substr(s, i + 1, 2))
          out = out sprintf("%c", index("0123456789ABCDEF", substr(hex, 1, 1)) * 16 - 16 + index("0123456789ABCDEF", substr(hex, 2, 1)) - 1)
          i += 2
        } else {
          out = out substr(s, i, 1)
        }
      }
      return out
    }
    $2 == "NOTATION_NAME" { reading = (unescape($3) == want); if (reading) { names++ } ; next }
    $2 == "NOTATION_DATA" && reading { data = data unescape(substr($0, index($0, $3))) ; next }
    $2 != "NOTATION_FLAGS" { reading = 0 }
    END { if (names == 1) { print data } else { print "\001" names } }' <<<"$1"
}

for file in "$@"; do
  # A signature gpg refuses is reported below, with this script's own status.
  status=$(gpg --homedir "${work}/verify" --batch --status-fd 1 --verify "${file}.asc" "${file}" 2>/dev/null) || true
  signatures=$(grep -c '^\[GNUPG:\] NEWSIG' <<<"${status}" || true)
  validsig=$(awk '$2 == "VALIDSIG" {print $3, $NF; exit}' <<<"${status}")
  case ${form} in
    home) good='GOODSIG' want="${subkey} ${primary}" ;;
    certificate) good='GOODSIG|EXPKEYSIG' want="${validsig% *} ${primary}" ;;
    *) usage ;;
  esac
  if [[ ${signatures} != 1 ]] || ! grep -qE "^\[GNUPG:\] (${good}) " <<<"${status}" ||
    grep -qE '^\[GNUPG:\] (REVKEYSIG|BADSIG|ERRSIG|EXPSIG) ' <<<"${status}" || [[ ${validsig} != "${want}" ]]; then
    printf 'gpg does not verify %s as one signature by C1 %s\n' "${file}" "${primary}" >&2
    exit 70
  fi
  if [[ ${notation} != - ]]; then
    carried=$(notation_of "${status}")
    [[ ${carried} == "${notation}" ]] || {
      printf '%s names the run %s, not %s\n' "${file}.asc" "${carried}" "${notation}" >&2
      exit 70
    }
  fi
  sqv --keyring "${work}/public.pgp" "${file}.asc" "${file}" >/dev/null || {
    printf 'sqv does not verify %s\n' "${file}" >&2
    exit 70
  }
done
printf 'verified under gpg and sqv: %d signatures\n' "$#"
