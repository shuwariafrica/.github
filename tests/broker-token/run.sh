#!/usr/bin/env bash
# Runs the broker-token action's step as the runner runs it, through its own action.yml. In the
# exported-function case the job's environment carries a function `curl` (BASH_FUNC_curl%%), as any
# earlier step can put one there through GITHUB_ENV. It records every header file it is handed and
# answers as GitHub and the broker would, with a token of its own; the step must neither hand it the
# OIDC request token nor output its token. The OIDC endpoint and the broker are 127.0.0.1:1, which
# refuses at once, so nothing leaves the machine.
# Usage: run.sh [--tree <directory>] [<case>...]
#   --tree  a tree holding actions/broker-token; this repository's by default, or another commit's
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
readonly tree ACTION="${tree}/actions/broker-token/action.yml"
for tool in yq /usr/bin/jq /usr/bin/curl mktemp; do
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
  mkdir -p "${directory}"
  : >"${directory}/output"
  printf '%s\n' "${directory}"
}

defaults() { # case directory: the step's inputs, the job's environment and the runner's variables
  input=([app]=release_bot [permissions]='{"contents":"read"}' ["broker-url"]=http://127.0.0.1:1/broker)
  caller=(PATH=/usr/bin:/bin "HOME=$1")
  runner=("GITHUB_OUTPUT=$1/output" "GITHUB_ACTION_PATH=${tree}/actions/broker-token"
    'ACTIONS_ID_TOKEN_REQUEST_URL=http://127.0.0.1:1/token?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=oidc-request-secret)
}

# The function `curl`: each header file to <leak>; then GitHub's OIDC answer, or the broker's 200 with
# a token of its own written where -o names.
planted_curl() { # leak file
  printf '%s' "BASH_FUNC_curl%%=() { local a out=''; while ((\$# > 0)); do case \$1 in -H) [[ \$2 != @* ]] || cat \"\${2#@}\" >>$1; shift 2 ;;" \
    " -o) out=\$2; shift 2 ;; *) shift ;; esac; done;" \
    " if [[ -n \${out} ]]; then printf '{\"token\": \"forged-installation-token\", \"permissions\": {}, \"repository_ids\": [], \"expires_at\": \"never\"}' >\"\${out}\"; printf 200;" \
    " else printf '{\"value\": \"forged-oidc\"}'; fi; }"
}

case_exported_function() {
  local d function status
  local -a found=()
  d=$(fresh exported_function)
  defaults "${d}"
  function=$(planted_curl "${d}/leak")
  caller+=("${function}")
  step "${ACTION}" 0 "${d}"
  status=$(<"${d}/status")
  [[ ! -e ${d}/leak ]] || found+=("the job's function curl was handed: $(<"${d}/leak")")
  ! grep -q '^token=' "${d}/output" || found+=("the step output the function's token: $(<"${d}/output")")
  [[ ${status} != 0 ]] || found+=('the step passed with no broker reached')
  ((${#found[@]} == 0)) || fail "${found[@]}"
}

case_no_request_token() {
  local d status
  d=$(fresh no_request_token)
  defaults "${d}"
  runner=("${runner[@]:0:3}")
  step "${ACTION}" 0 "${d}"
  status=$(<"${d}/status")
  [[ ${status} == 1 ]] || fail "exit ${status}, not 1"
  grep -qF 'this job cannot request an OIDC token' "${d}/stdout" || fail 'no refusal for the absent token'
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
