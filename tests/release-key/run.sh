#!/usr/bin/env bash
# Runs release-key/verify's step as the runner runs it (verify/action.yml's shell, its `run` and its
# step env written over the caller's environment), and release-key's import and sign step scripts
# with a stand-in curl, against keys made here. Nothing leaves the machine.
# The function cases plant an exported function in the caller's environment: `set`, which a bash
# not in POSIX mode runs in place of the builtin, and `sqv`, which reaches verify.sh unless the step
# hands it a clean environment. Each must leave verify's refusal standing.
# Usage: run.sh [--tree <directory>] [<case>...]
#   --tree  a tree holding actions/release-key; this repository's by default, or another commit's
#           (`git archive <commit> actions`) to show a case red there.
# Prints `ok` or `FAIL` per case and the counts. Exit 0 when every case named (all by default)
# passed; 1 when one failed; 64 for usage; 69 for an absent tool.
# Needs gpg, gpgconf, sqv, yq (mikefarah's), jq and sha256sum.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly here
# shellcheck source=tests/step.sh
. "${here}/../step.sh"
tree=$(cd -- "${here}/../.." && pwd)
cases=()
while (($# > 0)); do
  case $1 in
    --tree)
      tree=$(cd -- "$2" && pwd)
      shift 2
      ;;
    -*)
      printf 'usage: run.sh [--tree <directory>] [<case>...]\n' >&2
      exit 64
      ;;
    *)
      cases+=("$1")
      shift
      ;;
  esac
done
readonly tree
for tool in gpg gpgconf sqv yq jq sha256sum mktemp; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '%s not found\n' "${tool}" >&2
    exit 69
  }
done
yq_version=$(yq --version)
[[ ${yq_version} == *mikefarah* ]] || {
  printf 'yq is not mikefarah'"'"'s: %s\n' "${yq_version}" >&2
  exit 69
}

readonly NOTATION=1295027104:refs/tags/v1.2.3
work=$(mktemp -d)
readonly work
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
  local home
  for home in "${work}"/keys/*/ "${work}"/cases/*/temp/release-gnupg/; do
    [[ -d ${home} ]] || continue
    gpgconf --homedir "${home}" --kill all 2>/dev/null || true # its agent may never start
  done
  rm -rf -- "${work}"
}
trap cleanup EXIT

g() { # home, gpg argument...
  local home=$1
  shift
  gpg --homedir "${work}/keys/${home}" --batch --quiet --pinentry-mode loopback --passphrase '' "$@"
}

fingerprint() { # home: the primary's fingerprint
  g "$1" --with-colons --list-keys | awk -F: '$1 == "fpr" {print $10; exit}'
}

subkey() { # home: the signing subkey's fingerprint
  g "$1" --with-colons --list-keys | awk -F: '$1 == "sub" && $12 ~ /s/ {want = 1; next} $1 == "fpr" && want {print $10; exit}'
}

key() { # home: a cert-only primary with one signing subkey, as C1 is
  local primary
  mkdir -m 700 "${work}/keys/$1"
  g "$1" --quick-gen-key "C1 <c1@shuwari.africa>" ed25519 cert 2y
  primary=$(fingerprint "$1")
  g "$1" --quick-add-key "${primary}" ed25519 sign 2y
}

# A file under <case>/release signed by <home>'s subkey with the notation, gpg option... added.
signed() { # case directory, home, gpg option...
  local directory=$1 home=$2 sub
  shift 2
  sub=$(subkey "${home}")
  mkdir -p "${directory}/release"
  printf 'a release\n' >"${directory}/release/SHA256SUMS"
  g "${home}" "$@" --sig-notation "repository-ref@shuwari.africa=${NOTATION}" --local-user "${sub}!" \
    --armor --detach-sign --output "${directory}/release/SHA256SUMS.asc" "${directory}/release/SHA256SUMS"
}

fresh() { # case name: prints its directory
  local directory="${work}/cases/$1"
  mkdir -p "${directory}/temp"
  : >"${directory}/output"
  printf '%s\n' "${directory}"
}

declare -A input=() over=()
caller=() runner=()

verify() { # case directory: verify's step, as the runner runs it
  runner=("RUNNER_TEMP=$1/temp" "GITHUB_ACTION_PATH=${tree}/actions/release-key/verify")
  step "${tree}/actions/release-key/verify/action.yml" 0 "$1"
}

fail() {
  printf '    %s\n' "$@" >&2
  return 1
}

expect() { # case directory, exit status, text stdout or stderr must hold
  local status tail
  status=$(<"$1/status")
  tail=$(tail -n 5 "$1/stderr")
  [[ ${status} == "$2" ]] || fail "exit ${status}, not $2" "${tail}"
  grep -qF -- "$3" "$1/stdout" "$1/stderr" || fail "neither stdout nor stderr holds: $3" "${tail}"
}

home_form() { # case directory: verify's inputs for the home form of C1's own home
  input=([directory]="$1/release" [gnupghome]="${work}/keys/c1" [subkey]="${sub_c1}" ["repository-ref"]="${NOTATION}")
}

case_verify_home() {
  local d
  d=$(fresh verify_home)
  signed "${d}" c1
  home_form "${d}"
  verify "${d}"
  expect "${d}" 0 'verified under gpg and sqv: 1 signatures'
}

case_verify_other_key() {
  local d
  d=$(fresh verify_other_key)
  signed "${d}" impostor
  home_form "${d}"
  verify "${d}"
  expect "${d}" 70 'gpg does not verify'
}

# gpg 2.4 admits a SHA-1 data signature; sqv's policy refuses it, so verify's refusal is sqv's.
case_verify_weak_hash() {
  local d
  d=$(fresh verify_weak_hash)
  signed "${d}" c1 --digest-algo SHA1
  home_form "${d}"
  verify "${d}"
  expect "${d}" 70 'sqv does not verify'
}

# A `set` that exits 0 ends a bash not in POSIX mode at its first line, before anything is verified.
case_verify_function_set() {
  local d
  d=$(fresh verify_function_set)
  signed "${d}" impostor
  home_form "${d}"
  caller+=('BASH_FUNC_set%%=() { builtin exit 0; }')
  verify "${d}"
  expect "${d}" 2 'is a special builtin'
}

# An `sqv` that answers 0 stands for sqv in every script the step's environment reaches.
case_verify_function_tool() {
  local d
  d=$(fresh verify_function_tool)
  signed "${d}" c1 --digest-algo SHA1
  home_form "${d}"
  caller+=('BASH_FUNC_sqv%%=() { return 0; }')
  verify "${d}"
  expect "${d}" 70 'sqv does not verify'
}

# The stand-in answers the OIDC request, Entra's token grant and Key Vault's Get Secret of the secret
# named (c1-subkey by default), each only for the credential the step before it handed on.
standin_curl() { # case directory, the subkey-only export, the secret's name
  local secret=${3:-c1-subkey}
  mkdir -p "$1/bin"
  jq -Rs '{value: .}' "$2" >"$1/secret.json"
  cat >"$1/bin/curl" <<CURL
#!/usr/bin/env bash
set -euo pipefail
header='' post=no
while ((\$# > 0)); do
  case \$1 in
    --header) header=\${2#@} && shift 2 ;;
    --request) post=yes && shift 2 ;;
    --data-urlencode) shift 2 ;;
    https://*) url=\$1 && shift ;;
    *) shift ;;
  esac
done
if [[ \${url} == https://token.example/* ]]; then
  [[ \$(<"\${header}") == 'Authorization: bearer request-token' ]]
  printf '{"value": "oidc-assertion"}\n'
elif [[ \${post} == yes ]]; then
  printf '{"access_token": "vault-token"}\n'
else
  [[ \$(<"\${header}") == 'Authorization: Bearer vault-token' && \${url} == https://release.vault.azure.net/secrets/${secret}?* ]]
  cat '$1/secret.json'
fi
CURL
  chmod 755 "$1/bin/curl"
}

import_step() { # case directory, request token (empty for none on descriptor 3), SECRET=<name> or nothing
  local status=0 primary
  local -a secret=()
  primary=$(fingerprint c1)
  [[ -z ${3:-} ]] || secret=("$3")
  if [[ -n $2 ]]; then
    env -i PATH="$1/bin:/usr/bin:/bin" "${secret[@]}" TENANT_ID=tenant CLIENT_ID=client VAULT_URL=https://release.vault.azure.net \
      FINGERPRINT="${primary}" RUNNER_TEMP="$1/temp" GITHUB_OUTPUT="$1/output" \
      ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example/request \
      bash --noprofile --norc "${tree}/actions/release-key/import-step.sh" 3<<<"$2" >"$1/stdout" 2>"$1/stderr" || status=$?
  else
    env -i PATH="$1/bin:/usr/bin:/bin" TENANT_ID=tenant CLIENT_ID=client VAULT_URL=https://release.vault.azure.net \
      FINGERPRINT="${primary}" RUNNER_TEMP="$1/temp" GITHUB_OUTPUT="$1/output" \
      ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example/request \
      bash --noprofile --norc "${tree}/actions/release-key/import-step.sh" 3</dev/null >"$1/stdout" 2>"$1/stderr" || status=$?
  fi
  printf '%s\n' "${status}" >"$1/status"
}

case_import_and_sign() {
  local d home status masks tail
  d=$(fresh import_and_sign)
  g c1 --armor --export-secret-subkeys >"${d}/export.asc"
  standin_curl "${d}" "${d}/export.asc"
  import_step "${d}" request-token
  expect "${d}" 0 'release key: C1'
  home="${d}/temp/release-gnupg"
  [[ $(<"${d}/output") == "gnupghome=${home}"$'\n'"subkey=${sub_c1}" ]] || fail "GITHUB_OUTPUT holds $(<"${d}/output")"
  masks=$(grep -c '^::add-mask::' "${d}/stdout" || true)
  ((masks > 0)) || fail 'no line of the export was masked'
  mkdir -p "${d}/release"
  printf 'one\n' >"${d}/release/one"
  printf 'two\n' >"${d}/release/two"
  status=0
  env -i PATH=/usr/bin:/bin FILES="${d}/release/one"$'\n\n'"${d}/release/two"$'\n' GNUPGHOME="${home}" SUBKEY="${sub_c1}" \
    REPOSITORY_REF="${NOTATION}" bash --noprofile --norc "${tree}/actions/release-key/sign-step.sh" \
    >"${d}/sign.stdout" 2>"${d}/sign.stderr" || status=$?
  tail=$(tail -n 5 "${d}/sign.stderr")
  [[ ${status} == 0 ]] || fail "sign-step.sh exit ${status}" "${tail}"
  grep -qF 'signed: 2 files' "${d}/sign.stdout" || fail "sign-step.sh: $(<"${d}/sign.stdout")"
  input=([directory]="${d}/release" [gnupghome]="${home}" [subkey]="${sub_c1}" ["repository-ref"]="${NOTATION}")
  verify "${d}"
  expect "${d}" 0 'verified under gpg and sqv: 2 signatures'
}

case_import_no_token() {
  local d
  d=$(fresh import_no_token)
  standin_curl "${d}" /dev/null
  import_step "${d}" ''
  expect "${d}" 64 'no OIDC request token on descriptor 3'
  [[ ! -s ${d}/output ]] || fail "GITHUB_OUTPUT holds $(<"${d}/output")"
}

# The secret the action's `secret` input names is the one read: a project's key, here C1's own
# made again, in its vault's secret `subkey`.
case_import_a_secret_named() {
  local d fpr default
  d=$(fresh import_secret_named)
  fpr=$(fingerprint c1)
  g c1 --armor --export-secret-subkeys >"${d}/export.asc"
  standin_curl "${d}" "${d}/export.asc" subkey
  import_step "${d}" request-token SECRET=subkey
  expect "${d}" 0 "release key: subkey ${fpr}, signing subkey ${sub_c1}"
  default=$(yq -r '.inputs.secret.default' "${tree}/actions/release-key/action.yml")
  [[ ${default} == c1-subkey ]] || fail "the secret input defaults to ${default}"
}

# published.sh over a keyserver: one that holds nothing for the key leaves nothing; one that does
# not answer (127.0.0.1:1 refuses at once) refuses.
case_published_refuses_a_keyserver_that_does_not_answer() {
  local d status=0 fpr
  d=$(fresh published)
  fpr=$(fingerprint c1)
  g c1 --armor --export "${fpr}" >"${d}/c1.asc"
  mkdir -p "${d}/bin" "${d}/published" "${d}/silent"
  printf '#!/usr/bin/env bash\nprintf 404\n' >"${d}/bin/curl"
  chmod 755 "${d}/bin/curl"
  env -i PATH="${d}/bin:/usr/bin:/bin" bash --noprofile --norc "${tree}/actions/release-key/published.sh" "${d}/c1.asc" \
    "${d}/published" https://hkp.example https://vks.example >"${d}/stdout" 2>"${d}/stderr" || status=$?
  printf '%s\n' "${status}" >"${d}/status"
  expect "${d}" 0 "published for ${fpr}: 0 files"
  status=0
  env -i PATH=/usr/bin:/bin bash --noprofile --norc "${tree}/actions/release-key/published.sh" "${d}/c1.asc" \
    "${d}/silent" http://127.0.0.1:1 http://127.0.0.1:1 >"${d}/stdout" 2>"${d}/stderr" || status=$?
  printf '%s\n' "${status}" >"${d}/status"
  expect "${d}" 75 'did not answer for'
}

# Where the caller's environment holds BASH_SOURCE, bash never fills the array, so a script would
# take its own directory from the caller: each script that reads it refuses to run.
case_scripts_refuse_a_bash_source_from_the_environment() {
  local d script status
  d=$(fresh bash_source)
  for script in import-step.sh sign-step.sh sign.sh verify-step.sh; do
    status=0
    env -i PATH=/usr/bin:/bin BASH_SOURCE=/elsewhere/script bash --noprofile --norc "${tree}/actions/release-key/${script}" \
      </dev/null >"${d}/stdout" 2>"${d}/stderr" || status=$?
    printf '%s\n' "${status}" >"${d}/status"
    expect "${d}" 2 "${tree}/actions/release-key/${script}: BASH_SOURCE is set by the environment"
  done
}

mkdir -p "${work}/keys" "${work}/cases"
key c1
key impostor
sub_c1=$(subkey c1)
readonly sub_c1

if ((${#cases[@]} == 0)); then
  listed=$(declare -F | awk '$3 ~ /^case_/ {print substr($3, 6)}')
  mapfile -t cases <<<"${listed}"
fi
passed=0 failed=0
for name in "${cases[@]}"; do
  declare -F "case_${name}" >/dev/null || {
    printf 'no case %s\n' "${name}" >&2
    exit 64
  }
  input=()
  caller=(PATH=/usr/bin:/bin "HOME=${work}" LANG=C.UTF-8)
  # Each case runs in a subshell of its own under -e, so its first failed assertion ends it.
  set +e
  (
    set -e
    "case_${name}"
  )
  status=$?
  set -e
  if ((status == 0)); then
    printf 'ok    %s\n' "${name}"
    passed=$((passed + 1))
  else
    printf 'FAIL  %s\n' "${name}"
    failed=$((failed + 1))
  fi
done
printf '%d passed, %d failed\n' "${passed}" "${failed}"
((failed == 0))
