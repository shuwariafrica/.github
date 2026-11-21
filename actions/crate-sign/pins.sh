# shellcheck shell=bash
# The run's pins, sourced by crate-sign's check step and crate-admit's: which commit of
# shuwariafrica/.github this action runs at, and whether a release.yml runs only actions at the
# commits the release holds them to. Needs yq (mikefarah's), awk and lib.sh's die.

# The commit of shuwariafrica/.github the action <name> runs at, from its directory <path>: the
# runner places a remote action at _actions/<owner>/<repo>/<ref as written>/<path>
# (actions/runner, ActionManager.cs's LoadAction), and gives a composite's own steps no
# github.action_ref. Refused unless that ref is a full commit.
own_commit() {
  local path=$1 name=$2 owner repo ref
  [[ ${path} =~ /_actions/([^/]+)/([^/]+)/([^/]+)/actions/${name}/?$ ]] ||
    die "this action runs from ${path}, not from a commit of shuwariafrica/.github"
  owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} ref=${BASH_REMATCH[3]}
  [[ ${owner,,}/${repo,,} == shuwariafrica/.github ]] || die "this action runs from ${owner}/${repo}, not shuwariafrica/.github"
  [[ ${ref} =~ ^[0-9a-f]{40}$ ]] || die "this action runs at ${ref}, not at a full commit"
  printf '%s\n' "${ref}"
}

# Every action and reusable workflow the workflow file <file> uses is one the organisation fixed:
# shuwariafrica/.github's at <own>, shuwariafrica/public-crates' at <gate>, or one listed in the
# third-party list <list> (.github's actions/third-party.tsv at <own>) at a commit listed for it.
# Owner and repository are read without case, as GitHub reads them; every mapping is read, after
# aliases are expanded, so a job's reusable workflow, a step and a parallel group's step alike.
# Prints each departure; returns 1 when there is one.
pins_hold() {
  local file=$1 own=$2 gate=$3 list=$4 listed kinds uses target ref named found=0
  kinds=$(yq -r '[explode(.) | .. | select(tag == "!!map" and has("uses")) | .uses | tag] | unique | join(" ")' "${file}" 2>&1) ||
    die "release.yml does not read as YAML: ${kinds//$'\n'/ }"
  [[ -z ${kinds} || ${kinds} == '!!str' ]] || die "release.yml holds a uses that is not a string"
  listed=$(yq -r 'explode(.) | .. | select(tag == "!!map" and has("uses")) | .uses' "${file}")
  while IFS= read -r uses; do
    [[ -n ${uses} ]] || continue
    target=${uses%@*} ref=${uses##*@}
    [[ ${uses} == *@* ]] || ref=''
    named=$(cut -d/ -f1-2 <<<"${target}")
    case ${named,,} in
      shuwariafrica/.github)
        [[ ${ref} == "${own}" ]] || {
          printf '%s is not at %s, the commit of shuwariafrica/.github this release runs\n' "${uses}" "${own}"
          found=1
        }
        ;;
      shuwariafrica/public-crates)
        [[ ${ref} == "${gate}" ]] || {
          printf '%s is not at %s, public-crates'"'"' gate-commit\n' "${uses}" "${gate}"
          found=1
        }
        ;;
      *)
        awk -F'\t' -v t="${target,,}" -v r="${ref}" 'tolower($1) == t && $2 == r {found = 1} END {exit !found}' "${list}" || {
          printf '%s is not on shuwariafrica/.github'"'"'s actions/third-party.tsv at that commit\n' "${uses}"
          found=1
        }
        ;;
    esac
  done <<<"${listed}"
  return "${found}"
}
