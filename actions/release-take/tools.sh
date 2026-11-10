#!/usr/bin/env bash
# Installs the take's own gh and sqv into a new <directory>, each fixed by the SHA-256 of what it is
# extracted from: gh from its release archive, sqv from Ubuntu's package. Each download is checked
# against its digest before anything reads it; each tool is then run once, so one built for another
# machine fails here.
# Usage: tools.sh <directory> <gh archive URL> <its sha256> <sqv package URL> <its sha256>
# Exit 0 with <directory>/gh and <directory>/sqv in place; 64 for usage; 65 for a download that is
# not the one its digest names, or holds no tool; 69 for an absent tool.
set -euo pipefail

[[ $# -eq 5 ]] || {
  printf 'usage: tools.sh <directory> <gh archive URL> <its sha256> <sqv package URL> <its sha256>\n' >&2
  exit 64
}
directory=$1 gh_url=$2 gh_sha256=$3 sqv_url=$4 sqv_sha256=$5
[[ ${gh_sha256} =~ ^[0-9a-f]{64}$ && ${sqv_sha256} =~ ^[0-9a-f]{64}$ ]] || {
  printf 'a digest is 64 lower-case hexadecimal digits\n' >&2
  exit 64
}
[[ ! -e ${directory} ]] || {
  printf '%s exists; the tools go into a new directory\n' "${directory}" >&2
  exit 64
}
for tool in curl sha256sum tar dpkg-deb install mktemp; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '%s not found\n' "${tool}" >&2
    exit 69
  }
done
work=$(mktemp -d)
readonly work
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() { rm -rf -- "${work}"; }
trap cleanup EXIT

curl --fail --silent --show-error --location --output "${work}/gh.tar.gz" "${gh_url}"
printf '%s  %s\n' "${gh_sha256}" "${work}/gh.tar.gz" | sha256sum --check --strict --status || {
  printf 'the gh archive at %s is not the one this action fixes (%s)\n' "${gh_url}" "${gh_sha256}" >&2
  exit 65
}
curl --fail --silent --show-error --location --output "${work}/sqv.deb" "${sqv_url}"
printf '%s  %s\n' "${sqv_sha256}" "${work}/sqv.deb" | sha256sum --check --strict --status || {
  printf 'the sqv package at %s is not the one this action fixes (%s)\n' "${sqv_url}" "${sqv_sha256}" >&2
  exit 65
}

mkdir "${work}/gh" "${work}/sqv"
tar --extract --gzip --file "${work}/gh.tar.gz" --directory "${work}/gh"
found=("${work}"/gh/*/bin/gh)
[[ ${#found[@]} -eq 1 && -f ${found[0]} ]] || {
  printf 'the gh archive holds no */bin/gh\n' >&2
  exit 65
}
dpkg-deb --fsys-tarfile "${work}/sqv.deb" | tar --extract --directory "${work}/sqv" ./usr/bin/sqv
mkdir -m 755 "${directory}"
install -m 755 "${found[0]}" "${directory}/gh"
install -m 755 "${work}/sqv/usr/bin/sqv" "${directory}/sqv"
gh_version=$("${directory}/gh" --version)
sqv_version=$("${directory}/sqv" --version)
printf 'tools: %s; %s\n' "${gh_version%%$'\n'*}" "${sqv_version}"
