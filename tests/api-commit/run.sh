#!/usr/bin/env bash
# Runs the api-commit action's step as the runner runs a node24 action: github-script's
# dist/index.js under node, with the step's env and each github-script input as INPUT_<NAME>.
# - In the exported-function case the job's environment carries functions (BASH_FUNC_<name>%%), as any
#   earlier step can put them there through GITHUB_ENV. The step runs no bash, so they must reach
#   nothing.
# - In the loader case it carries LD_PRELOAD, naming a library whose constructor copies the token
#   input; the step's own env must keep it out of node.
# - In the NODE_OPTIONS case the job's `env:` names a module for node to import first, which copies
#   the token input; GITHUB_ENV refuses that name, a job's `env:` does not.
# - In the proxy case it carries https_proxy, naming proxy.py, and NODE_TLS_REJECT_UNAUTHORIZED=0;
#   the proxy must not read the token.
# The API is 127.0.0.1:1, which refuses at once, except in the proxy case, which names
# api.github.com and so runs only in a network namespace holding loopback alone (podman run
# --network none); nothing leaves the machine.
# Usage: run.sh --github-script <directory> [--tree <directory>] [<case>...]
#   --github-script  a checkout of actions/github-script at the commit action.yml pins;
#   --tree           a tree holding actions/api-commit; this repository's by default, or another
#                    commit's (`git archive <commit> actions`) to show a case red there.
# Prints `ok` or `FAIL` per case and the counts. Exit 0 when every case named (all by default)
# passed; 1 when one failed; 64 for usage; 69 for an absent tool.
# Needs node, cc, git, python3, openssl, yq (mikefarah's) and jq.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly here
tree=$(cd -- "${here}/../.." && pwd)
script=''
cases=()
usage() {
  printf 'usage: run.sh --github-script <directory> [--tree <directory>] [<case>...]\n' >&2
  exit 64
}
while (($# > 0)); do
  case $1 in
    --tree)
      tree=$(cd -- "$2" && pwd)
      shift 2
      ;;
    --github-script)
      script=$(cd -- "$2" && pwd)
      shift 2
      ;;
    -*) usage ;;
    *)
      cases+=("$1")
      shift
      ;;
  esac
done
[[ -n ${script} ]] || usage
readonly tree script ACTION="${tree}/actions/api-commit/action.yml"
for tool in node cc git python3 openssl yq jq mktemp; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '%s not found\n' "${tool}" >&2
    exit 69
  }
done
node=$(command -v node)
readonly node
uses=$(yq -r '.runs.steps[0].uses' "${ACTION}")
checkout=$(git -C "${script}" rev-parse HEAD)
[[ ${uses} == "actions/github-script@${checkout}" ]] || {
  printf 'the step uses %s; %s is at %s\n' "${uses}" "${script}" "${checkout}" >&2
  exit 64
}
work=$(mktemp -d)
readonly work
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() { rm -rf -- "${work}"; }
trap cleanup EXIT

declare -A input=()
caller=()
api=http://127.0.0.1:1

fail() {
  printf '    %s\n' "$@" >&2
  return 1
}

# The runner's environment for the step: the job's, then the step's env, then each github-script
# input as INPUT_<NAME> (its default unless `with` gives it), then the runner's own variables.
# Leaves status, stdout and stderr in <directory>.
node_step() { # directory
  local directory=$1 line key value expression status with
  local -a lines env
  env=("${caller[@]}")
  line=$(yq -r '.runs.steps[0].env | to_entries | .[] | .key + "=" + (.value | @json)' "${ACTION}")
  mapfile -t lines <<<"${line}"
  for line in "${lines[@]}"; do
    key=${line%%=*}
    value=$(jq -r . <<<"${line#*=}")
    while [[ ${value} =~ \$\{\{\ inputs\.([a-z-]+)\ \}\} ]]; do
      expression=${BASH_REMATCH[0]}
      value=${value/"${expression}"/"${input[${BASH_REMATCH[1]}]}"}
    done
    env+=("${key}=${value}")
  done
  line=$(yq -r '.inputs | to_entries | .[] | .key + "=" + ((.value.default // "") | tostring | @json)' "${script}/action.yml")
  mapfile -t lines <<<"${line}"
  for line in "${lines[@]}"; do
    key=${line%%=*}
    value=$(jq -r . <<<"${line#*=}")
    # The two defaults that are expressions: the token, which `with` gives, and debug, off.
    [[ ${value} != "\${{ runner.debug == '1' }}" ]] || value=false
    with=$(yq -r ".runs.steps[0].with[\"${key}\"] // \"\"" "${ACTION}")
    if [[ -n ${with} ]]; then
      value=${with}
      while [[ ${value} =~ \$\{\{\ inputs\.([a-z-]+)\ \}\} ]]; do
        expression=${BASH_REMATCH[0]}
        value=${value/"${expression}"/"${input[${BASH_REMATCH[1]}]}"}
      done
    fi
    env+=("INPUT_${key^^}=${value}")
  done
  env+=("GITHUB_ACTION_PATH=${tree}/actions/api-commit" "GITHUB_API_URL=${api}"
    "GITHUB_GRAPHQL_URL=${api}/graphql" GITHUB_REPOSITORY=shuwariafrica/example)
  status=0
  (cd "${directory}/workspace" && env -i "${env[@]}" "${node}" "${script}/dist/index.js") \
    >"${directory}/stdout" 2>"${directory}/stderr" || status=$?
  printf '%s\n' "${status}" >"${directory}/status"
}

fresh() { # case name: prints its directory
  local directory="${work}/$1"
  mkdir -p "${directory}/workspace"
  printf 'content\n' >"${directory}/workspace/file.txt"
  printf '%s\n' "${directory}"
}

defaults() { # case directory: the step's inputs and the job's environment
  input=([token]=installation-token [paths]=file.txt [message]='Update file.txt' [branch]=main
    [repository]=shuwariafrica/example)
  caller=(PATH=/usr/bin:/bin "HOME=$1")
}

# Proof the step ran api-commit.js to its first request, whatever else the case asserts.
reached_api() { # case directory
  local tail
  tail=$(tail -n 3 "$1/stderr")
  grep -qE 'ECONNREFUSED|fetch failed' "$1/stdout" "$1/stderr" || fail "the step did not reach the API: ${tail}"
}

case_exported_function() {
  local d name status
  local -a found=()
  d=$(fresh exported_function)
  defaults "${d}"
  for name in node bash sh git curl; do
    caller+=("BASH_FUNC_${name}%%=() { printf '%s ran\\n' ${name} >>${d}/marker; }")
  done
  node_step "${d}"
  status=$(<"${d}/status")
  [[ ! -e ${d}/marker ]] || found+=("an exported function ran: $(<"${d}/marker")")
  [[ ${status} != 0 ]] || found+=('the step passed with no API reached')
  ((${#found[@]} == 0)) || fail "${found[@]}"
  reached_api "${d}"
}

case_loader() {
  local d
  d=$(fresh loader)
  defaults "${d}"
  cat >"${d}/leak.c" <<'C'
#include <stdio.h>
#include <stdlib.h>

__attribute__((constructor)) static void leak(void) {
  const char *token = getenv("INPUT_GITHUB-TOKEN"), *path = getenv("LEAK_FILE");
  FILE *file;
  if (token == NULL || path == NULL || (file = fopen(path, "a")) == NULL) return;
  fprintf(file, "%s\n", token);
  fclose(file);
}
C
  cc -shared -fPIC -o "${d}/leak.so" "${d}/leak.c"
  caller+=("LD_PRELOAD=${d}/leak.so" "LEAK_FILE=${d}/leak")
  node_step "${d}"
  [[ ! -e ${d}/leak ]] || fail "a library the job's LD_PRELOAD named copied the token: $(<"${d}/leak")"
  reached_api "${d}"
}

case_node_options() {
  local d
  d=$(fresh node_options)
  defaults "${d}"
  caller+=("NODE_OPTIONS=--import=data:text/javascript,import('fs').then((f)=>f.appendFileSync('${d}/leak',process.env['INPUT_GITHUB-TOKEN']))")
  node_step "${d}"
  [[ ! -e ${d}/leak ]] || fail "a module the job's NODE_OPTIONS named copied the token: $(<"${d}/leak")"
  reached_api "${d}"
}

case_proxy() {
  local d port interfaces proxy
  # Each network interface is a link under /sys/class/net; loopback must be the only one.
  interfaces=$(find /sys/class/net -mindepth 1 -maxdepth 1 -type l -printf '%f ')
  [[ ${interfaces} == 'lo ' ]] || fail "the proxy case names api.github.com and runs only with loopback alone, not: ${interfaces}"
  d=$(fresh proxy)
  defaults "${d}"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=api.github.com \
    -keyout "${d}/key.pem" -out "${d}/certificate.pem" 2>/dev/null
  python3 -I "${here}/proxy.py" "${d}/port" "${d}/proxy.log" "${d}/certificate.pem" "${d}/key.pem" </dev/null &
  proxy=$!
  until [[ -s ${d}/port ]]; do read -r -t 0.05 <> <(:) || true; done
  port=$(<"${d}/port")
  caller+=("https_proxy=http://127.0.0.1:${port}" NODE_TLS_REJECT_UNAUTHORIZED=0)
  api=https://api.github.com
  node_step "${d}"
  kill "${proxy}"
  ! grep -q installation-token "${d}/proxy.log" 2>/dev/null || fail "the job's proxy read: $(<"${d}/proxy.log")"
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
