# shellcheck shell=bash
# What the crate-* actions' steps share, sourced by each: public-crates' main read anonymously, a
# project's entry and signing certificate there, the release's files held to crate-package's
# digest, SHA256SUMS.asc verified against the project's key, the upload bodies held to the signed
# crates, and crates.io's index and API. git reaches public-crates at GIT_BASE; every other read is
# curl's, with the User-Agent crates.io's data-access policy asks of a client.

readonly CATALOGUE=shuwariafrica/public-crates
CRATE_LIB=$(realpath -- "${BASH_SOURCE[0]}")
readonly CRATE_LIB
readonly AGENT='shuwariafrica-crate-release (https://github.com/shuwariafrica/.github)'
# git's configuration for every git run is the command line's alone.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0

# The release is refused: <reason>, as the run's error.
die() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

# Something the decision needs could not be read: <what>. The release is neither admitted nor
# refused, and a re-run may decide it.
unreadable() {
  printf '::error::%s\n' "$*" >&2
  exit 75
}

# Each tool named is on PATH.
tools() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || {
      printf '%s not found\n' "${tool}" >&2
      exit 69
    }
  done
}

# The status of a GET of <url> into <file>, 000 when nothing answered; further curl options after.
fetch() {
  local url=$1 file=$2 code
  shift 2
  code=$(curl --silent --show-error --location --max-time 60 --user-agent "${AGENT}" "$@" \
    --output "${file}" --write-out '%{http_code}' "${url}") || code=000
  printf '%s' "${code}"
}

# public-crates' main, fetched anonymously into the new repository <dir>; its commit printed.
catalogue() {
  local dir=$1 answer rc=0
  git init --quiet -- "${dir}"
  answer=$(git -C "${dir}" fetch --quiet --depth 1 --no-tags -- "${GIT_BASE:?}/${CATALOGUE}" \
    +refs/heads/main:refs/heads/main 2>&1) || rc=$?
  ((rc == 0)) || unreadable "public-crates' main cannot be read: ${answer//$'\n'/ }"
  git -C "${dir}" rev-parse refs/heads/main
}

# The file <path> of the catalogue <dir> at the main it fetched, printed.
catalogue_file() {
  git -C "$1" show "refs/heads/main:$2" 2>/dev/null || die "public-crates' main holds no $2"
}

# The project of the catalogue <dir> whose repository is <repository>, printed as its entry with
# its key as .name. Refused unless exactly one entry names it, keyed by the repository's own name,
# with the id <repository id> and a signing key.
project_of() {
  local dir=$1 repository=$2 id=$3 projects found
  projects=$(catalogue_file "${dir}" projects.json)
  found=$(jq -c --arg r "${repository}" '[.projects | to_entries[] | select(.value.repository == $r)
    | .value + {name: .key}]' <<<"${projects}" 2>/dev/null) || die "public-crates' projects.json does not read"
  jq -e 'length == 1' <<<"${found}" >/dev/null || die "${repository} is not one project of public-crates' projects.json"
  jq -e --arg r "${repository}" '.[0].name == ($r | split("/")[1])' <<<"${found}" >/dev/null ||
    die "public-crates' projects.json keys ${repository} by another name than its own"
  jq -e '.[0].repository_id != null' <<<"${found}" >/dev/null ||
    die "public-crates' projects.json holds no repository_id for ${repository} yet"
  jq -e --argjson id "${id}" '.[0].repository_id == $id' <<<"${found}" >/dev/null ||
    die "${repository} is repository ${id}, which public-crates' projects.json does not name"
  jq -e '.[0].signing_key | type == "string" and test("^[0-9A-F]{40}$")' <<<"${found}" >/dev/null ||
    die "public-crates' projects.json holds no signing_key for ${repository}: its key is not yet made"
  jq -e '.[0] | (.crates | type == "array" and length > 0 and all(.[]; type == "string"))
    and (.tag_signers | type == "array" and all(.[]; type == "string"))
    and (.crates_io_owners | type == "array" and all(.[]; type == "string"))
    and (.platforms | type == "array" and all(.[]; type == "string"))
    and (.first_version | type == "string")' <<<"${found}" >/dev/null ||
    die "public-crates' projects.json entry for ${repository} lacks a field the release reads"
  jq -c '.[0]' <<<"${found}"
}

# The project's signing certificate, signing-keys/<name>.asc of the catalogue <dir>, into <out>,
# held to <fingerprint>: one primary, that one, imported into the new home <home>.
certificate_of() {
  local dir=$1 name=$2 out=$3 fingerprint=$4 home=$5 listing primaries
  git -C "${dir}" show "refs/heads/main:signing-keys/${name}.asc" >"${out}" 2>/dev/null ||
    die "public-crates' main holds no signing-keys/${name}.asc"
  mkdir -m 700 -- "${home}"
  gpg --homedir "${home}" --batch --quiet --import "${out}" 2>/dev/null ||
    die "signing-keys/${name}.asc does not import"
  listing=$(gpg --homedir "${home}" --batch --with-colons --list-keys)
  primaries=$(awk -F: '$1 == "pub" {want = 1; next} $1 == "fpr" && want {print $10; want = 0}' <<<"${listing}")
  [[ ${primaries} == "${fingerprint}" ]] ||
    die "signing-keys/${name}.asc holds [${primaries//$'\n'/ }], not the project's signing_key ${fingerprint} alone"
}

# The keys of <certificate> the keyservers publish as revoked, one fingerprint a line: what
# release-key's published.sh fetches for its primary, merged into a copy in the new home <home> by
# merge-only, which adds only what that primary signed, and read for gpg's validity `r`. Neither
# copy enters the home a signature is verified in, so a keyserver adds no key there. A keyserver
# that does not answer refuses (published.sh's 75).
revoked_keys() {
  local certificate=$1 home=$2 published=$2.published file rc=0 listing
  mkdir -m 700 -- "${home}"
  mkdir -- "${published}"
  "${CRATE_LIB%/*}/../release-key/published.sh" "${certificate}" "${published}" >/dev/null || rc=$?
  ((rc == 0)) || unreadable "the keyservers did not answer for the project's certificate (${rc})"
  gpg --homedir "${home}" --batch --quiet --import "${certificate}" 2>/dev/null
  for file in "${published}"/*; do
    [[ -f ${file} ]] || continue
    gpg --homedir "${home}" --batch --quiet --import-options merge-only --import "${file}" 2>/dev/null ||
      die "what a keyserver publishes for the project's key does not import: ${file##*/}"
  done
  listing=$(gpg --homedir "${home}" --batch --with-colons --list-keys)
  awk -F: '($1 == "pub" || $1 == "sub") {revoked = ($2 == "r"); next} $1 == "fpr" && revoked {print $10; revoked = 0}' <<<"${listing}"
}

# The files a release of <crates json> at <version> signs, one name a line: each crate's `.crate`
# and `.upload`, then `order` and `changelog.md`.
release_files() {
  jq -r --arg v "$2" '.[] | "\(.)-\($v).crate", "\(.)-\($v).upload"' <<<"$1"
  printf 'order\nchangelog.md\n'
}

# The release's files in <dir> are crate-package's: SHA256SUMS is the file whose SHA-256 is
# <digest>, it names exactly the files of <crates json> at <version>, each matches its digest, and
# `order` lists those crates alone. Beside them only SHA256SUMS.asc may lie.
check_files() {
  local dir=$1 digest=$2 crates=$3 version=$4 found named expected present file order listed
  [[ -f ${dir}/SHA256SUMS ]] || die "${dir} holds no SHA256SUMS"
  found=$(sha256sum -- "${dir}/SHA256SUMS")
  [[ ${found%% *} == "${digest}" ]] || die "SHA256SUMS is ${found%% *}, and package made ${digest}"
  named=$(awk '{name = $2; sub(/^\*/, "", name); print name}' "${dir}/SHA256SUMS")
  named=$(LC_ALL=C sort <<<"${named}")
  expected=$(release_files "${crates}" "${version}")
  expected=$(LC_ALL=C sort <<<"${expected}")
  [[ ${named} == "${expected}" ]] ||
    die "SHA256SUMS names [${named//$'\n'/ }], and the admitted crates' files are [${expected//$'\n'/ }]"
  (cd -- "${dir}" && sha256sum --check --strict --quiet SHA256SUMS) || die "a file in ${dir} is not the one SHA256SUMS names"
  present=$(find "${dir}" -mindepth 1 -maxdepth 1 -printf '%f\n')
  while IFS= read -r file; do
    case ${file} in
      SHA256SUMS | SHA256SUMS.asc | '') ;;
      *) grep -qxF -- "${file}" <<<"${expected}" || die "${file} is not a file SHA256SUMS names" ;;
    esac
  done <<<"${present}"
  order=$(LC_ALL=C sort <"${dir}/order")
  listed=$(jq -r '.[]' <<<"${crates}")
  listed=$(LC_ALL=C sort <<<"${listed}")
  [[ ${order} == "${listed}" ]] || die "the signed order is not the admitted crates"
}

# SHA256SUMS.asc in <dir> is one good signature over SHA256SUMS by a key whose primary is
# <fingerprint>, verified by gpg in <home>, which holds the project's certificate alone, and made by
# no key of <revoked>, the keyservers' revoked keys one a line. gpg gives each signature one of
# GOODSIG, EXPSIG, EXPKEYSIG, REVKEYSIG, BADSIG or ERRSIG, so one signature and one GOODSIG refuse
# a SHA-1 signature, an expired or revoked key, another key and any second signature.
verify_sums() {
  local dir=$1 home=$2 fingerprint=$3 revoked=$4 status signatures goods validsig signer primary
  # gpg's exit is not the verdict: its status lines are.
  status=$(gpg --homedir "${home}" --batch --weak-digest SHA1 --status-fd 1 \
    --verify "${dir}/SHA256SUMS.asc" "${dir}/SHA256SUMS" 2>/dev/null) || true
  signatures=$(grep -c '^\[GNUPG:\] NEWSIG' <<<"${status}" || true) # 0 is answered below
  goods=$(grep -c '^\[GNUPG:\] GOODSIG ' <<<"${status}" || true)    # as above
  validsig=$(awk '$2 == "VALIDSIG" {print $3, $NF; exit}' <<<"${status}")
  signer=${validsig% *} primary=${validsig#* }
  if [[ ${signatures} != 1 || ${goods} != 1 ]]; then
    die "SHA256SUMS.asc is not one good signature under the project's signing certificate"
  fi
  [[ ${primary} == "${fingerprint}" ]] || die "SHA256SUMS is signed by ${primary:-no key}, not the project's ${fingerprint}"
  ! grep -qxF -e "${signer}" -e "${primary}" <<<"${revoked}" ||
    die "SHA256SUMS is signed by ${signer}, which the keyservers publish as revoked"
}

# SHA256SUMS.asc in <dir> verified for the project <project json> of the catalogue <dir>: against
# its certificate in signing-keys/, held to its signing_key, and the keyservers' revocations of
# it, in new homes under <work>.
verify_release() {
  local dir=$1 catalogue=$2 project=$3 work=$4 name fingerprint revoked
  name=$(jq -r '.name' <<<"${project}")
  fingerprint=$(jq -r '.signing_key' <<<"${project}")
  certificate_of "${catalogue}" "${name}" "${work}/signing.asc" "${fingerprint}" "${work}/verify"
  revoked=$(revoked_keys "${work}/signing.asc" "${work}/revocations")
  verify_sums "${dir}" "${work}/verify" "${fingerprint}" "${revoked}"
}

# Every GnuPG home under <work> stopped, for its caller's EXIT trap.
stop_homes() {
  local home
  for home in "$1"/*/; do
    gpgconf --homedir "${home%/}" --kill all 2>/dev/null || true # its agent may never have started
  done
}

# The upload body <upload> carries the file <crate> as crates.io's `PUT /api/v1/crates/new` reads
# it: a 32-bit little-endian length, that much JSON naming <name> and <version>, a second such
# length and that much tarball, which is <crate>, and nothing after.
body_carries() {
  local upload=$1 crate=$2 name=$3 version=$4 size json_length tar_length json
  size=$(stat --format %s -- "${upload}")
  ((size >= 8)) || return 1
  json_length=$(od --address-radix=n --format=u4 --endian=little --read-bytes=4 -- "${upload}")
  json_length=${json_length//[[:space:]]/}
  ((json_length <= size - 8)) || return 1
  tar_length=$(od --address-radix=n --format=u4 --endian=little --skip-bytes="$((4 + json_length))" \
    --read-bytes=4 -- "${upload}")
  tar_length=${tar_length//[[:space:]]/}
  ((size == 8 + json_length + tar_length)) || return 1
  json=$(dd if="${upload}" iflag=skip_bytes,count_bytes skip=4 count="${json_length}" bs=65536 status=none)
  jq -e --arg n "${name}" --arg v "${version}" '.name == $n and .vers == $v' >/dev/null 2>&1 <<<"${json}" || return 1
  cmp --silent --ignore-initial="$((8 + json_length)):0" -- "${upload}" "${crate}"
}

# The sparse index's path for a crate name (crates.io's relative_index_file_for_url).
index_path() {
  local name=${1,,}
  case ${#name} in
    1) printf '1/%s' "${name}" ;;
    2) printf '2/%s' "${name}" ;;
    3) printf '3/%s/%s' "${name:0:1}" "${name}" ;;
    *) printf '%s/%s/%s' "${name:0:2}" "${name:2:2}" "${name}" ;;
  esac
}

# The checksum crates.io's index holds for <name> at <version>, printed; nothing when the crate or
# that version is unknown to it. <work> is a directory for the answer.
index_digest() {
  local name=$1 version=$2 work=$3 path code
  path=$(index_path "${name}")
  code=$(fetch "${INDEX:?}/${path}" "${work}/index")
  case ${code} in
    200) jq -r --arg v "${version}" 'select(.vers == $v) | .cksum' "${work}/index" ;;
    404) ;;
    *) unreadable "crates.io's index answered ${code} for ${name}" ;;
  esac
}

# Waits until a second has passed since the last read of crates.io's API, which its data-access
# policy asks of a client ("A maximum of 1 request per second"); the time of each is kept in
# <clock>, a file every process of the step shares.
api_pace() {
  local clock=$1 last=0 now wait
  [[ ! -s ${clock} ]] || last=$(<"${clock}")
  now=$(date +%s%N)
  wait=$((last + 1000000000 - now))
  if ((wait > 0)); then
    sleep "$((wait / 1000000000)).$(printf '%09d' "$((wait % 1000000000))")"
  fi
}

# crates.io's answer for the crate <name> at <path> under its API (`` for the crate, `/owners` for
# its owners), printed; `null` when the crate is unknown. <work> holds the pacing clock and answer.
crates_io() {
  local name=$1 path=$2 work=$3 code
  api_pace "${work}/clock"
  code=$(fetch "${CRATES_IO:?}/api/v1/crates/${name}${path}" "${work}/answer")
  date +%s%N >"${work}/clock"
  case ${code} in
    200) cat -- "${work}/answer" ;;
    404) printf 'null\n' ;;
    *) unreadable "crates.io answered ${code} for ${name}${path}" ;;
  esac
}

# Whether crates.io's owner list <answer> is the logins <owners json> exactly, users alone.
owners_match() {
  jq -e --argjson want "$2" '([.users[] | select(.kind != "user")] | length) == 0
    and ([.users[] | .login] | sort) == ($want | sort)' <<<"$1" >/dev/null
}
