#!/usr/bin/env bash
# Sourced by this repository's action tests: `step` runs one `run` step of an action's action.yml as
# the runner runs it. It takes the step's shell (`bash` meaning the runner's own template), writes its
# `run` to a file, and runs it in a clean environment of three layers, each later one winning:
#   - `caller`, the job's environment;
#   - the step's env, each ${{ inputs.<name> }} replaced from `input`, and each name in `over`
#     replaced whole;
#   - `runner`, the variables the runner writes after the step env.
# Globals: input and over (associative arrays), caller and runner (arrays), all set by the sourcer.
# Needs yq (mikefarah's) and jq.
# shellcheck disable=SC2154 # input, over, caller and runner are the sourcer's
set -euo pipefail

# shellcheck disable=SC2016 # the opening of a GitHub expression, as text
readonly STEP_EXPRESSION='${{'

# Leaves `status`, `stdout` and `stderr` in <directory>; runs in <working directory>, by default
# <directory>.
step() { # action.yml, step index, directory, working directory
  local action=$1 index=$2 directory=$3 cwd=${4:-$3} shell line key value expression status
  local -a lines env words
  shell=$(yq -r ".runs.steps[${index}].shell" "${action}")
  yq -r ".runs.steps[${index}].run" "${action}" >"${directory}/step.sh"
  line=$(yq -r ".runs.steps[${index}].env | to_entries | .[] | .key + \"=\" + (.value | @json)" "${action}")
  mapfile -t lines <<<"${line}"
  env=()
  for line in "${lines[@]}"; do
    key=${line%%=*}
    value=$(jq -r . <<<"${line#*=}")
    if [[ -n ${over[${key}]+set} ]]; then
      value=${over[${key}]}
    else
      while [[ ${value} =~ \$\{\{\ inputs\.([a-z-]+)\ \}\} ]]; do
        expression=${BASH_REMATCH[0]}
        value=${value/"${expression}"/"${input[${BASH_REMATCH[1]}]}"}
      done
      [[ ${value} != *"${STEP_EXPRESSION}"* ]] || {
        printf 'step.sh: %s holds an expression no test stands in for: %s\n' "${key}" "${value}" >&2
        exit 70
      }
    fi
    env+=("${key}=${value}")
  done
  [[ ${shell} != bash ]] || shell='bash --noprofile --norc -e -o pipefail {0}'
  read -r -a words <<<"${shell//\{0\}/${directory}/step.sh}"
  status=0
  (cd "${cwd}" && env -i "${caller[@]}" "${env[@]}" "${runner[@]}" "${words[@]}") \
    >"${directory}/stdout" 2>"${directory}/stderr" || status=$?
  printf '%s\n' "${status}" >"${directory}/status"
}
