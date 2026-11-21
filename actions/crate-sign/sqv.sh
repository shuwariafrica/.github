#!/usr/bin/env bash
# Installs sqv, which release-key's verification runs from /usr/bin, as release-take's tools.sh
# installs its own: Ubuntu's package, checked against its SHA-256 before anything reads it, unpacked
# into the new <directory>, run once so a binary built for another machine fails here, then
# installed as <destination> through sudo, since the image's /usr/bin is root's.
# Usage: sqv.sh <directory> <package URL> <its sha256> <destination>
# Exit 0 with <destination> in place; 64 for usage; 65 for a download that is not the one its
# digest names, or holds no sqv; 69 for an absent tool.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

[[ $# -eq 4 ]] || {
  printf 'usage: sqv.sh <directory> <package URL> <its sha256> <destination>\n' >&2
  exit 64
}
directory=$1 url=$2 sha256=$3 destination=$4
[[ ${sha256} =~ ^[0-9a-f]{64}$ ]] || {
  printf 'a digest is 64 lower-case hexadecimal digits\n' >&2
  exit 64
}
[[ ! -e ${directory} ]] || {
  printf '%s exists; sqv goes into a new directory\n' "${directory}" >&2
  exit 64
}
for tool in curl sha256sum tar dpkg-deb sudo; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '%s not found\n' "${tool}" >&2
    exit 69
  }
done
mkdir -m 755 -- "${directory}"
curl --fail --silent --show-error --location --output "${directory}/sqv.deb" "${url}"
printf '%s  %s\n' "${sha256}" "${directory}/sqv.deb" | sha256sum --check --strict --status || {
  printf 'the sqv package at %s is not the one this action fixes (%s)\n' "${url}" "${sha256}" >&2
  exit 65
}
mkdir -- "${directory}/package"
dpkg-deb --fsys-tarfile "${directory}/sqv.deb" | tar --extract --directory "${directory}/package" ./usr/bin/sqv
[[ -f ${directory}/package/usr/bin/sqv ]] || {
  printf 'the sqv package holds no ./usr/bin/sqv\n' >&2
  exit 65
}
version=$("${directory}/package/usr/bin/sqv" --version)
sudo -n install -m 755 -- "${directory}/package/usr/bin/sqv" "${destination}"
printf 'sqv: %s, installed as %s\n' "${version}" "${destination}"
