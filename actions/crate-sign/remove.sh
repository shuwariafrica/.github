#!/usr/bin/env bash
# crate-sign's last step, run however the steps before it ended: stops the agent of the GnuPG home
# release-key's import made under RUNNER_TEMP and removes the home, then fails unless it is gone.
# The export file is removed by the import step itself.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

home=${RUNNER_TEMP:?}/release-gnupg
if [[ -e ${home} ]]; then
  gpgconf --homedir "${home}" --kill all 2>/dev/null || true # its agent may never have started
  rm -rf -- "${home}"
fi
[[ ! -e ${home} ]] || {
  printf '::error::%s is still there\n' "${home}" >&2
  exit 1
}
printf 'the signing key'"'"'s home is gone\n'
