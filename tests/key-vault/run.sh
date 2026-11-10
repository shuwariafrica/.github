#!/usr/bin/env bash
# Runs the key-vault action's step as the runner runs it, through its own action.yml. In the
# exported-function case the job's environment carries a function `curl` (BASH_FUNC_curl%%), as any
# earlier step can put one there through GITHUB_ENV. It records every header file it is handed and
# answers as Entra and Key Vault would, with values of its own; the step must neither hand it the
# OIDC request token nor write its value. The OIDC endpoint is 127.0.0.1:1, which refuses at once, so
# nothing leaves the machine.
# Usage: run.sh [--tree <directory>] [<case>...]
#   --tree  a tree holding actions/key-vault; this repository's by default, or another commit's
#           (`git archive <commit> actions`) to show a case red there.
# Prints `ok` or `FAIL` per case and the counts. Exit 0 when every case named (all by default)
# passed; 1 when one failed; 64 for usage; 69 for an absent tool.
# Needs yq (mikefarah's), jq and curl in /usr/bin.
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
readonly tree ACTION="${tree}/actions/key-vault/action.yml"
for tool in yq jq /usr/bin/curl mktemp; do
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

declare -A input=() over=()
caller=() runner=()

fail() {
  printf '    %s\n' "$@" >&2
  return 1
}

fresh() { # case name: prints its directory
  local directory="${work}/$1"
  mkdir -p "${directory}/workspace" "${directory}/temp"
  printf '%s\n' "${directory}"
}

defaults() { # case directory: the step's inputs, the job's environment and the runner's variables
  local directory=$1
  input=([operation]=get ["tenant-id"]=tenant ["client-id"]=client ["vault-url"]=https://release.vault.azure.net
    [secret]=c1-subkey [file]=secret.txt)
  caller=(PATH=/usr/bin:/bin "HOME=${directory}")
  runner=("RUNNER_TEMP=${directory}/temp" "GITHUB_ACTION_PATH=${tree}/actions/key-vault"
    ACTIONS_ID_TOKEN_REQUEST_URL=http://127.0.0.1:1/token ACTIONS_ID_TOKEN_REQUEST_TOKEN=oidc-request-secret)
}

# The function `curl`: each header file to <leak>, then Entra's and Key Vault's answers, its own.
planted_curl() { # leak file
  printf '%s' "BASH_FUNC_curl%%=() { local a; for a in \"\$@\"; do [[ \${a} != @* ]] || cat \"\${a#@}\" >>$1; done;" \
    " if [[ \" \$* \" == *' --get '* ]]; then printf '{\"value\": \"forged-assertion\"}';" \
    " elif [[ \" \$* \" == *' POST '* ]]; then printf '{\"access_token\": \"forged-access\"}';" \
    " else printf '{\"value\": \"forged-secret\"}'; fi; }"
}

case_exported_function() {
  local d function status
  local -a found=()
  d=$(fresh exported_function)
  defaults "${d}"
  function=$(planted_curl "${d}/leak")
  caller+=("${function}")
  step "${ACTION}" 0 "${d}" "${d}/workspace"
  status=$(<"${d}/status")
  [[ ! -e ${d}/leak ]] || found+=("the job's function curl was handed: $(<"${d}/leak")")
  [[ ! -e ${d}/workspace/secret.txt ]] ||
    found+=("the step wrote the function's value as the secret: $(<"${d}/workspace/secret.txt")")
  [[ ${status} != 0 ]] || found+=('the step passed with no vault reached')
  ((${#found[@]} == 0)) || fail "${found[@]}"
}

case_unknown_operation() {
  local d status
  d=$(fresh unknown_operation)
  defaults "${d}"
  input[operation]=list
  step "${ACTION}" 0 "${d}" "${d}/workspace"
  status=$(<"${d}/status")
  [[ ${status} == 64 ]] || fail "exit ${status}, not 64"
  grep -qF 'operation is get, set, absent or token, not list' "${d}/stderr" || fail 'no refusal of the operation'
}

case_no_request_token() {
  local d status
  d=$(fresh no_request_token)
  defaults "${d}"
  runner=("${runner[@]:0:3}")
  step "${ACTION}" 0 "${d}" "${d}/workspace"
  status=$(<"${d}/status")
  [[ ${status} == 64 ]] || fail "exit ${status}, not 64"
  grep -qF 'the job needs permissions: id-token: write' "${d}/stderr" || fail 'no refusal for the absent token'
}

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
