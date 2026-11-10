#!/usr/bin/env bash
# Shows each refusal red: for every refusal case of run.sh, the line of the action that holds it is
# changed in a copy of actions/ (deleted, made to pass, or moved after the placing), and that case
# must then fail. A mutant whose case still passes has SURVIVED, and the refusal is not shown held
# by that line.
# Usage: mutants.sh [--fixtures <directory>] [<case>...]   (every mutant by default; with cases, those
#        cases' mutants)
# Prints `red` or `SURVIVED` per mutant and the counts. Exit 0 when every mutant run is red; 1 when one
# survived; 70 when a mutant's text is not found exactly once in its file.
# Needs what run.sh needs.
# shellcheck disable=SC2016 # each mutant's texts are the action's source, never expanded here
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly here
tree=$(cd -- "${here}/../.." && pwd)
readonly tree
fixtures=''
if [[ ${1:-} == --fixtures ]]; then
  mkdir -p -- "$2"
  fixtures=$(cd -- "$2" && pwd)
  shift 2
fi
only=("$@")
work=$(mktemp -d)
readonly work
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() { rm -rf -- "${work}"; }
trap cleanup EXIT
[[ -n ${fixtures} ]] || fixtures="${work}/fixtures"
red=0 survived=0 index=0

# One mutant: <case> must fail once each <from> in <file> (under actions/) becomes <to>.
mutant() { # case, then file, from, to, repeated
  local name=$1 file from to content rest count copy status
  shift
  if ((${#only[@]} > 0)) && ! printf '%s\n' "${only[@]}" | grep -qxF -- "${name}"; then
    return 0
  fi
  index=$((index + 1))
  copy="${work}/mutant-${index}"
  rm -rf -- "${copy}"
  mkdir -p "${copy}"
  cp -R -- "${tree}/actions" "${copy}/"
  while (($# > 0)); do
    file="${copy}/actions/$1" from=$2 to=$3
    shift 3
    content=$(<"${file}")
    rest=${content//"${from}"/}
    count=$(((${#content} - ${#rest}) / ${#from}))
    ((count == 1)) || {
      printf 'mutant %d (%s): %q occurs %d times in %s\n' "${index}" "${name}" "${from}" "${count}" "${file#"${copy}/"}" >&2
      exit 70
    }
    printf '%s\n' "${content/"${from}"/"${to}"}" >"${file}"
  done
  status=0
  "${here}/run.sh" --tree "${copy}" --fixtures "${fixtures}" "${name}" >"${copy}/run.log" 2>&1 || status=$?
  if ((status == 1)); then
    printf 'red       %3d %s\n' "${index}" "${name}"
    red=$((red + 1))
  else
    printf 'SURVIVED  %3d %s (run.sh exit %d)\n' "${index}" "${name}" "${status}"
    survived=$((survived + 1))
  fi
}

t=release-take/take.sh g=release-take/tag.sh o=release-take/tools.sh a=release-take/action.yml
p=release-key/published.sh

# Item 1: a failed check fails the step.
mutant i1_failed_download "${t}" 'set -euo pipefail' 'set -uo pipefail'
mutant i1_shape "${a}" '      id: take' $'      id: take\n      continue-on-error: true'
mutant i1_shape "${a}" '--norc -e -o pipefail {0}' '--norc -o pipefail {0}'
# Item 2: nothing reaches path before every proof.
mutant i2_proofs_before_placing \
  "${t}" $'  place "${release}" "${GITHUB_WORKSPACE}" "${TAKE_PATH}" "${!digest_of[@]}"\n' '' \
  "${t}" $'  "${RELEASE_KEY}/published.sh" "${C1}"' $'  place "${release}" "${GITHUB_WORKSPACE}" "${TAKE_PATH}" "${!digest_of[@]}"\n  "${RELEASE_KEY}/published.sh" "${C1}"'
# Item 3: commit set only when everything passed, as the tag's commit.
mutant i5_workflow \
  "${t}" $'  printf \'commit=%s\\n\' "${commit}" >>"${GITHUB_OUTPUT}"\n' '' \
  "${t}" $'  published "${certificates}"' $'  printf \'commit=%s\\n\' "${commit}" >>"${GITHUB_OUTPUT}"\n  published "${certificates}"'
mutant i3_commit_form "${t}" $'  [[ ${commit} =~ ^[0-9a-f]{40}$ ]] || refuse 65 \'the tag %s names %q\' "$2" "${commit}"\n' ''
# Item 4: the tag, now, as the gate holds its own.
mutant i4_empty_tag "${t}" '[[ -n ${TAKE_TAG} ]] || refuse 64' 'true || refuse 64'
mutant i4_tag_form "${t}" 'is_tag "${TAKE_TAG}" || refuse 64' 'true || refuse 64'
mutant i4_lightweight "${t}" '[[ ${kind} == tag ]] ||' 'true ||'
mutant i4_ref_answer "${t}" '[[ ${ref} == "refs/tags/$2" ]] ||' 'true ||'
mutant i4_object_answer "${t}" '[[ ${sha} == "${object}" ]] ||' 'true ||'
mutant i4_renamed "${t}" '[[ ${named} == "$2" ]] ||' 'true ||'
mutant i4_not_commit "${t}" '[[ ${kind} == commit ]] ||' 'true ||'
mutant i4_unsigned "${t}" '[[ -s $3/payload && -s $3/signature ]] ||' 'true ||'
mutant i4_payload_commit "${g}" '[[ ${#header[@]} -eq 3 &&' 'true || [[ ${#header[@]} -eq 3 &&'
mutant i4_payload_tag "${g}" '[[ ${#header[@]} -eq 3 &&' 'true || [[ ${#header[@]} -eq 3 &&'
mutant i4_two_signatures "${g}" 'if [[ ${signatures} != 1 ||' 'if [[ ${signatures} == 0 ||'
mutant i4_outsider "${g}" $'  printf \'gpg does not verify the tag %s as one signature by an admitted key, unrevoked and unexpired\\n\' "${tag}" >&2\n  exit 70' '  :'
mutant i4_published_key "${g}" '--import-options merge-only --import' '--import'
mutant i4_weak_hash "${g}" 'sqv --keyring "${work}/keyring.pgp" "${signature}" "${payload}" >/dev/null ||' 'true ||'
# gpg reports a revoked or expired key in GOODSIG's place, so each is held by GOODSIG's requirement
# as well as by the refused list.
mutant i4_revoked "${g}" "grep -q '^\\[GNUPG:\\] GOODSIG '" "grep -qE '^\\[GNUPG:\\] (GOODSIG|REVKEYSIG) '" \
  "${g}" '|EXPKEYSIG|REVKEYSIG) ' '|EXPKEYSIG) '
mutant i4_expired "${g}" "grep -q '^\\[GNUPG:\\] GOODSIG '" "grep -qE '^\\[GNUPG:\\] (GOODSIG|EXPKEYSIG) '" \
  "${g}" '|EXPSIG|EXPKEYSIG|' '|EXPSIG|'
mutant i4_published_revocation "${g}" 'find "${published}" -type f -print0 >"${work}/published"' ': >"${work}/published"'
mutant i4_bad_publication "${g}" '--import-options merge-only --import "${file}" 2>/dev/null || {' '--import-options merge-only --import "${file}" 2>/dev/null || true || {'
mutant i4_silent_keyserver "${p}" '      exit 75' '      return 0'
# Item 5: the repository, workflow, ref and commit.
mutant i5_repository_id "${t}" '[[ ${id} == "$1" && ${owner} == "${OWNER_ID}" ]] ||' '[[ ${owner} == "${OWNER_ID}" ]] ||'
mutant i5_owner "${t}" '[[ ${id} == "$1" && ${owner} == "${OWNER_ID}" ]] ||' '[[ ${id} == "$1" ]] ||'
mutant i5_workflow "${t}" '--signer-workflow "github.com/${repository}/${TAKE_WORKFLOW}@refs/tags/${TAKE_TAG}" ' ''
mutant i5_source_ref "${t}" $'\n      --source-ref "refs/tags/${TAKE_TAG}" ' $'\n      '
mutant i5_source_digest "${t}" '--source-digest "${commit}" ' ''
mutant i5_self_hosted "${t}" ' --deny-self-hosted-runners' ''
mutant i5_identifier "${t}" '        attestation\ *)' $'        attestation\\ *) attested=$((attested + 1)) ;;\n        never)'
mutant i5_owner_identifier "${t}" '        attestation\ *)' $'        attestation\\ *) attested=$((attested + 1)) ;;\n        never)'
mutant i5_no_attestation "${t}" '[[ -s ${work}/attestations/sha256:${digest_of["${name}"]}.jsonl ]] ||' 'true ||'
# Item 6: a job the gate admitted, for this release.
mutant i6_other_release "${t}" '"${work}/published-c1" "${TAKE_REPOSITORY_ID}:refs/tags/${TAKE_TAG}"' '"${work}/published-c1" -'
mutant i6_statement "${t}" '"${work}/published-c1" "${TAKE_REPOSITORY_ID}:refs/tags/${TAKE_TAG}"' '"${work}/published-c1" -'
mutant i6_not_c1 "${t}" '"${RELEASE_KEY}/verify.sh" certificate' ': certificate'
mutant i6_unnamed_asset "${t}" "refuse 65 'the release holds %q, which SHA256SUMS does not name'" "true 65 ''"
mutant i6_missing_asset "${t}" "refuse 65 'SHA256SUMS names %q, which the release does not hold'" "true 65 ''"
mutant i6_digest "${t}" "refuse 65 'the release does not match its SHA256SUMS'" 'true'
mutant i6_subject_outside "${t}" "refuse 65 'an attestation of %q names the subject %q, which SHA256SUMS does not'" "true 65 ''"
mutant i6_sums_form "${t}" "refuse 65 'SHA256SUMS holds %q, not <sha256>  <name>'" "true 65 ''"
mutant i6_duplicate "${t}" "refuse 65 'SHA256SUMS names %q twice'" "true 65 ''"
# Item 7: the caller's environment changes nothing.
mutant i7_environment "${a}" 'exec /usr/bin/env -i PATH=/usr/bin:/bin' 'exec /usr/bin/env PATH=/usr/bin:/bin'
mutant i7_environment "${a}" $'        SHELLOPTS: ""\n' ''
mutant i7_environment "${a}" $'        LD_PRELOAD: ""\n' ''
mutant i7_environment "${t}" 'XDG_CACHE_HOME="${work}/cache" ' ''
mutant i7_environment "${t}" 'GH_HOST=github.com ' ''
mutant i7_special_builtin "${a}" 'shell: /usr/bin/bash --posix --noprofile --norc -e -o pipefail {0}' 'shell: bash'
# Item 8: the roots are the action's own commit's.
mutant i8_consumer_c1 "${t}" 'readonly C1="${root}/signing/c1-public.asc"' 'readonly C1="${GITHUB_WORKSPACE}/signing/c1-public.asc"'
mutant i8_consumer_core_keys "${t}" 'certificates="${root}/signing/core-keys"' 'certificates="${GITHUB_WORKSPACE}/signing/core-keys"'
mutant i8_no_c1 "${t}" '[[ -f ${C1} ]] ||' 'true ||'
mutant i8_no_core_keys "${t}" '[[ -f ${keys[0]} ]] ||' 'true ||'
# Item 9: the tools fixed by digest.
mutant i9_gh_digest "${o}" '"${work}/gh.tar.gz" | sha256sum --check --strict --status ||' '"${work}/gh.tar.gz" | true ||'
mutant i9_sqv_digest "${o}" '"${work}/sqv.deb" | sha256sum --check --strict --status ||' '"${work}/sqv.deb" | true ||'
# Item 10: names confined.
mutant i10_name_slash "${t}" '[[ -n $1 && $1 != */* && $1 != *..* &&' '[[ -n $1 && $1 != *..* &&'
mutant i10_name_dots "${t}" '[[ -n $1 && $1 != */* && $1 != *..* &&' '[[ -n $1 && $1 != */* &&'
mutant i10_link "${t}" '[[ ${entry} == f\ * ]] ||' 'true ||'
mutant i10_path_parent "${t}" '[[ ${segment} != . && ${segment} != .. ]] || return 1' 'true'
mutant i10_path_absolute "${t}" '[[ -n $1 && $1 != [/~]* &&' '[[ -n $1 &&'
mutant i10_path_github "${t}" '[[ ${segments[0],,} != .github ]]' 'true'
mutant i10_path_link "${t}" '[[ ! -L ${at} ]] ||' 'true ||'
mutant i10_path_exists "${t}" '[[ ! -e ${at}/${path} && ! -L ${at}/${path} ]] ||' 'true ||'

printf '%d red, %d survived\n' "${red}" "${survived}"
((survived == 0))
