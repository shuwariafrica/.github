#!/usr/bin/env bash
# Targets: GitHub's hosted Ubuntu 26.04 runner, under crate-package's step (bash 5.3, rustup in
# ~/.cargo/bin, git, jq), and a developer's Linux machine for its cases.
# crate-package's step: packages the admitted commit's crates with cargo's own command, which
# compiles nothing and runs nothing of the tree. The checkout CHECKOUT is this run's commit, clean.
# The admitted toolchain is installed with the image's rustup, and its cargo runs from the
# toolchain's own directory with RUSTUP_TOOLCHAIN set, a new CARGO_HOME and a target of its own,
# from a directory outside the tree, so cargo reads none of the tree's configuration (cargo reads
# it from the directory it runs in and that directory's parents, never the manifest's) and rustup
# none of its toolchain files. Writes into a new directory each crate's `.crate` and crates.io's
# upload body for it (`.upload`), `order` (CRATES, the publishing order), `changelog.md`
# (CHANGELOG.md's entry for VERSION) and SHA256SUMS over them; refuses a `.crate` not of CRATES at
# VERSION, and a crate of CRATES cargo did not package.
# Environment: CHECKOUT (relative to GITHUB_WORKSPACE), TOOLCHAIN, VERSION, CRATES, SHA, HOME,
# RUNNER_TEMP, GITHUB_OUTPUT, GITHUB_WORKSPACE.
# Writes directory and digest (SHA256SUMS's SHA-256) to GITHUB_OUTPUT.
# Exit 0 when packaged; 1 refused; 69 for an absent tool.
# shellcheck disable=SC2153 # the variables above are action.yml's env, checked in main
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

die() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

# The four bytes of <n> as a little-endian u32, as printf escapes.
le32() {
  local n=$1
  printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((n & 255)) $(((n >> 8) & 255)) $(((n >> 16) & 255)) $(((n >> 24) & 255))
}

# crates.io's upload body for <crate>: the JSON part's length, the JSON part, the tarball's length,
# the tarball (cargo's crates-io `publish`, crates.io's `read_json_metadata`).
upload_body() {
  local crate=$1 json=$2 out=$3 json_length tar_length json_bytes tar_bytes
  json_length=$(printf '%s' "${json}" | wc -c)
  tar_length=$(wc -c <"${crate}")
  json_bytes=$(le32 "${json_length}")
  tar_bytes=$(le32 "${tar_length}")
  {
    # shellcheck disable=SC2059 # the format is the length's escapes, made above
    printf "${json_bytes}"
    printf '%s' "${json}"
    # shellcheck disable=SC2059 # as above
    printf "${tar_bytes}"
    cat -- "${crate}"
  } >"${out}"
}

# CHANGELOG.md's section for <version>: from its heading (`## [<version>]` or `## <version>`) to the
# next level-two heading.
changelog_entry() {
  local file=$1 version=$2
  [[ -f ${file} ]] || {
    printf 'CHANGELOG.md is absent.\n'
    return 0
  }
  awk -v v="${version}" '
    /^## / { if (found) exit; h = $0; sub(/^## \[?/, "", h); sub(/[]] .*$|[]]$| .*$/, "", h); if (h == v) found = 1 }
    found { print }
    END { if (!found) printf "CHANGELOG.md holds no entry for %s.\n", v }' "${file}"
}

main() {
  local tree rustup work out bin metadata target packaged expected name crate package readme_file json manifest head
  local status list digest tool
  local -a names
  : "${CHECKOUT:?}" "${TOOLCHAIN:?}" "${VERSION:?}" "${CRATES:?}" "${SHA:?}" "${HOME:?}" "${RUNNER_TEMP:?}"
  : "${GITHUB_OUTPUT:?}" "${GITHUB_WORKSPACE:?}"
  for tool in git jq awk sha256sum find mktemp; do
    command -v "${tool}" >/dev/null 2>&1 || {
      printf '%s not found\n' "${tool}" >&2
      exit 69
    }
  done
  # GitHub's Ubuntu image installs rustup into the runner's home (runner-images, install-rust.sh).
  rustup=${HOME}/.cargo/bin/rustup
  [[ -x ${rustup} ]] || {
    printf '%s not found\n' "${rustup}" >&2
    exit 69
  }
  [[ ${TOOLCHAIN} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not one exact release: ${TOOLCHAIN}"
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z][A-Za-z0-9_-]{0,63}$"))' <<<"${CRATES}" >/dev/null ||
    die "admit's crates are not a list of crate names"
  [[ ${CHECKOUT} != /* && ${CHECKOUT} != *..* ]] || die "the checkout ${CHECKOUT} is not a path inside the workspace"
  tree=${GITHUB_WORKSPACE}/${CHECKOUT}
  [[ -f ${tree}/Cargo.toml ]] || die "${CHECKOUT} holds no Cargo.toml"
  head=$(git -C "${tree}" rev-parse HEAD)
  [[ ${head} == "${SHA}" ]] || die "the checkout is at ${head}, and the run's commit is ${SHA}"
  status=$(git -C "${tree}" status --porcelain --untracked-files=all)
  [[ -z ${status} ]] || die "the checkout is not clean: ${status//$'\n'/; }"
  work=$(mktemp -d -p "${RUNNER_TEMP}")
  out=$(mktemp -d -p "${RUNNER_TEMP}")
  (cd -- "${work}" && "${rustup}" toolchain install --profile minimal --no-self-update "${TOOLCHAIN}") >&2
  bin=$(cd -- "${work}" && "${rustup}" which --toolchain "${TOOLCHAIN}" cargo)
  bin=${bin%/cargo}
  export CARGO_HOME=${work}/cargo-home CARGO_TARGET_DIR=${work}/target RUSTUP_TOOLCHAIN=${TOOLCHAIN} PATH=${bin}:${PATH}
  mkdir -- "${CARGO_HOME}"
  (cd -- "${work}" && cargo package --manifest-path "${tree}/Cargo.toml" --workspace --locked --no-verify) >&2
  metadata=$(cd -- "${work}" && cargo metadata --manifest-path "${tree}/Cargo.toml" --no-deps --format-version 1 --locked)
  target=$(jq -er '.target_directory' <<<"${metadata}")
  packaged=$(find "${target}/package" -maxdepth 1 -name '*.crate' -printf '%f\n' | LC_ALL=C sort)
  expected=$(jq -r --arg v "${VERSION}" '.[] | "\(.)-\($v).crate"' <<<"${CRATES}" | LC_ALL=C sort)
  [[ ${packaged} == "${expected}" ]] || die "cargo packaged [${packaged//$'\n'/ }], and admit admitted [${expected//$'\n'/ }]"
  list=$(jq -r '.[]' <<<"${CRATES}")
  mapfile -t names <<<"${list}"
  for name in "${names[@]}"; do
    crate=${target}/package/${name}-${VERSION}.crate
    package=$(jq -c --arg n "${name}" --arg v "${VERSION}" '.packages[] | select(.name == $n and .version == $v)' <<<"${metadata}")
    [[ -n ${package} ]] || die "cargo metadata names no ${name} ${VERSION}"
    readme_file=$(jq -r '.readme // empty' <<<"${package}")
    # The readme's text exactly, as cargo sends it: --rawfile keeps its trailing newlines.
    if [[ -n ${readme_file} ]]; then
      manifest=$(jq -r '.manifest_path' <<<"${package}")
      json=$(jq -nc --arg name "${name}" --arg vers "${VERSION}" --rawfile readme "${manifest%/*}/${readme_file}" \
        --arg file "${readme_file}" '{name: $name, vers: $vers, readme: $readme, readme_file: $file}')
    else
      json=$(jq -nc --arg name "${name}" --arg vers "${VERSION}" '{name: $name, vers: $vers, readme: null, readme_file: null}')
    fi
    cp -- "${crate}" "${out}/"
    upload_body "${crate}" "${json}" "${out}/${name}-${VERSION}.upload"
  done
  printf '%s\n' "${list}" >"${out}/order"
  changelog_entry "${tree}/CHANGELOG.md" "${VERSION}" >"${out}/changelog.md"
  (cd -- "${out}" && sha256sum -- *.crate *.upload order changelog.md >SHA256SUMS)
  digest=$(sha256sum -- "${out}/SHA256SUMS")
  printf 'directory=%s\ndigest=%s\n' "${out}" "${digest%% *}" >>"${GITHUB_OUTPUT}"
  printf 'packaged %s at %s: SHA256SUMS %s\n' "${list//$'\n'/, }" "${VERSION}" "${digest%% *}"
}

if ! (return 0 2>/dev/null); then
  main "$@"
  exit
fi
