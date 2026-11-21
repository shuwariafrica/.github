#!/usr/bin/env bash
# Runs crate-admit's step over a project repository and public-crates made here (tests/crates.sh):
# tag objects written as git writes them, signed by keys made, and later revoked, under faked times,
# then checked at the real clock; the tagged tree read as data; release.yml's pins and platforms.
# Usage: run.sh [--tree <directory>] [<case>...]; tests/crates.sh says the rest.
# Needs gpg, gpgconf, git, python3 3.11 or later, jq, yq (mikefarah's) and sha256sum.
set -euo pipefail
shopt -s inherit_errexit
unset CDPATH

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
# shellcheck source=tests/step.sh
. "${HERE}/../step.sh"
# shellcheck source=tests/crates.sh
. "${HERE}/../crates.sh"
TOOLS=(python3)

# The admission's further keys: self (a primary that signs), retire (as tag, its subkey revoked by a
# case after it signs), lapse (a primary that signs and has expired).
more_keys() {
  [[ -d ${WORK}/keys/self ]] && return 0
  make_key self cert,sign never
  make_key retire cert never subkey
  make_key lapse cert,sign 2d
}

# The case's world: public-crates listing the tag signers of the key homes <home>... (tag by
# default) with their certificates in keys/, and the project's repository with its main.
world() {
  local d=$1 home fpr signers='[]'
  shift
  (($# > 0)) || set -- tag
  more_keys
  catalogue_repo "${d}"
  for home in "$@"; do
    fpr=$(primary_of "${home}")
    g "${home}" --armor --export "${fpr}" >"${d}/git/shuwariafrica/public-crates/keys/${fpr}.asc"
    signers=$(jq -c --arg f "${fpr}" '. + [$f]' <<<"${signers}")
  done
  catalogue_edit "${d}" ".projects.probe.tag_signers = ${signers}"
  PROJECT=${d}/git/shuwariafrica/probe
  git init --quiet -b main -- "${PROJECT}"
}

# public-crates' projects.json edited by the jq filter <filter>, committed.
catalogue_edit() {
  local repo=$1/git/shuwariafrica/public-crates
  jq "$2" "${repo}/projects.json" >"${repo}/projects.next"
  mv -- "${repo}/projects.next" "${repo}/projects.json"
  git -C "${repo}" add -A
  git -C "${repo}" -c user.name=t -c user.email=t@example.invalid commit --quiet --no-gpg-sign --allow-empty -m edit
}

write() { # path, content: the project's file
  mkdir -p -- "$(dirname -- "${PROJECT}/$1")"
  printf '%s' "$2" >"${PROJECT}/$1"
}

# The project's tree: a workspace of two crates at <version>, probe-b depending on probe-a, each
# with its description and the workspace's licence, its toolchain exact, its root cargo
# configuration holding the two keys it may, and its release.yml.
tree_at() {
  find "${PROJECT}" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
  write Cargo.toml "[workspace]
members = [\"crates/*\"]
resolver = \"3\"

[workspace.package]
version = \"$1\"
license = \"Apache-2.0\"
"
  write crates/probe-a/Cargo.toml '[package]
name = "probe-a"
version.workspace = true
edition = "2024"
description = "The first probe."
license.workspace = true
'
  write crates/probe-a/src/lib.rs ''
  write crates/probe-b/Cargo.toml "[package]
name = \"probe-b\"
version.workspace = true
edition = \"2024\"
description = \"The second probe.\"
license.workspace = true

[dependencies]
probe-a = { path = \"../probe-a\", version = \"$1\" }
"
  write crates/probe-b/src/lib.rs ''
  write rust-toolchain.toml '[toolchain]
channel = "1.99.1"
components = ["rustfmt", "clippy"]
'
  write .cargo/config.toml '[registry]
global-min-publish-age = "7 days"

[resolver]
incompatible-publish-age = "deny"
'
  mkdir -p -- "${PROJECT}/.github/workflows"
  release_yml "${PROJECT}/.github/workflows/release.yml"
}

commit() { # the project's tree committed on its current branch; the commit printed
  git -C "${PROJECT}" add -A
  git -C "${PROJECT}" -c user.name=Probe -c user.email=probe@example.invalid commit --quiet --no-gpg-sign --allow-empty -m state
  git -C "${PROJECT}" rev-parse HEAD
}

# A tag object as git writes one, naming <name> and <target> (of KIND, commit by default), signed
# nine days ago by the key home <home> with gpg's further options, or unsigned where <home> is
# `unsigned`; written into the project, its id printed.
tag_object() {
  local name=$1 target=$2 home=$3 kind=${KIND:-commit} d=${PROJECT%/git/*}
  shift 3
  printf 'object %s\ntype %s\ntag %s\ntagger Probe <probe@example.invalid> %s +0000\n\n%s\n' \
    "${target}" "${kind}" "${name}" "${TAGGED}" "${name}" >"${d}/payload"
  cp -- "${d}/payload" "${d}/object"
  if [[ ${home} != unsigned ]]; then
    g "${home}" --faked-system-time "${SIGNED}" "$@" --yes --armor --detach-sign --output "${d}/payload.asc" "${d}/payload"
    cat -- "${d}/payload.asc" >>"${d}/object"
  fi
  git -C "${PROJECT}" hash-object -t tag -w ${LITERALLY:+--literally} -- "${d}/object"
}

ref() { git -C "${PROJECT}" update-ref "refs/tags/$1" "$2"; }

# The tree at <version> committed, tagged v<version> and signed by <home>; the commit in TARGET.
tagged() {
  local version=$1 home=$2 object
  tree_at "${version}"
  TARGET=$(commit)
  object=$(tag_object "v${version}" "${TARGET}" "${home}")
  ref "v${version}" "${object}"
}

# crate-admit's step over the case's world for the tag <tag>, at the run's commit TARGET.
admit() {
  local d=$1 tag=$2 path
  path=$(action_path crate-admit)
  run_script "${d}" crate-admit/admit-step.sh EVENT="${EVENT_OVER:-push}" REPOSITORY=shuwariafrica/probe \
    REPOSITORY_ID="${ID}" REF="refs/tags/${tag}" SHA="${SHA_OVER:-${TARGET}}" GITHUB_ACTION_PATH="${path}"
}

# The tree as the case left it, committed, tagged v1.2.3 by the key tag and admitted.
again() {
  local d=$1 object
  TARGET=$(commit)
  object=$(tag_object v1.2.3 "${TARGET}" tag)
  ref v1.2.3 "${object}"
  admit "${d}" v1.2.3
}

admitted() { # case: the last run admitted the release
  expect "$1" 0 'admitted v'
}

case_a_tag_by_a_listed_signers_subkey_is_admitted_with_its_facts() {
  local d object
  d=$(fresh good)
  world "${d}"
  tagged 1.2.3 tag
  admit "${d}" v1.2.3
  admitted "${d}"
  out_is "${d}" version 1.2.3
  out_is "${d}" crates '["probe-a","probe-b"]'
  out_is "${d}" toolchain 1.99.1
  out_is "${d}" commit "${TARGET}"
  object=$(git -C "${PROJECT}" rev-parse refs/tags/v1.2.3)
  out_is "${d}" object "${object}"
  out_is "${d}" signer "${TAG_SUBKEY}"
  out_is "${d}" primary "${TAG_KEY}"
  grep -q "admitted v1.2.3 of shuwariafrica/probe at ${TARGET}" "${d}/summary" || fail 'the summary names no admission'
}

case_the_step_runs_as_its_action_step_runs_it() {
  local d
  d=$(fresh wired)
  world "${d}"
  tagged 1.2.3 tag
  over=([EVENT]=push [REPOSITORY]=shuwariafrica/probe [REPOSITORY_ID]="${ID}" [REF]=refs/tags/v1.2.3 [SHA]="${TARGET}"
    [GIT_BASE]="file://${d}/git")
  wired "${d}" crate-admit 0
  admitted "${d}"
}

case_a_tag_by_a_listed_primary_is_admitted() {
  local d self
  d=$(fresh primary)
  world "${d}" self
  tagged 1.2.3 self
  admit "${d}" v1.2.3
  admitted "${d}"
  self=$(primary_of self)
  out_is "${d}" signer "${self}"
}

case_a_subkey_since_revoked_as_superseded_is_refused() {
  local d home subkey fpr
  d=$(fresh superseded)
  more_keys
  home=$(own_key retire superseded)
  world "${d}" "${home}"
  tagged 1.2.3 "${home}"
  fpr=$(primary_of "${home}")
  printf 'key 1\nrevkey\ny\n2\nsuperseded\n\ny\nsave\n' |
    g "${home}" --faked-system-time "${REVOKED}" --command-fd 0 --edit-key "${fpr}"
  subkey=$(subkey_of "${home}")
  g "${home}" --armor --export "${fpr}" >"${d}/git/shuwariafrica/public-crates/keys/${fpr}.asc"
  catalogue_edit "${d}" .
  admit "${d}" v1.2.3
  expect "${d}" 1 "${subkey} is revoked"
}

case_a_key_since_expired_is_refused() {
  local d lapse
  d=$(fresh expired)
  world "${d}" lapse
  tagged 1.2.3 lapse
  admit "${d}" v1.2.3
  lapse=$(primary_of lapse)
  expect "${d}" 1 "${lapse} has expired"
}

case_a_signer_outside_the_projects_keys_is_refused() {
  local d
  d=$(fresh outside)
  world "${d}"
  tagged 1.2.3 stranger
  admit "${d}" v1.2.3
  expect "${d}" 1 'no admitted key made the signature (issuers '
}

case_a_present_but_unlisted_primary_is_refused() {
  local d
  d=$(fresh unlisted)
  world "${d}"
  g stranger --armor --export >>"${d}/git/shuwariafrica/public-crates/keys/${TAG_KEY}.asc"
  catalogue_edit "${d}" .
  tagged 1.2.3 stranger
  admit "${d}" v1.2.3
  expect "${d}" 1 "${STRANGER_KEY} is not one of the project's tag signers"
}

case_an_unsigned_tag_is_refused() {
  local d
  d=$(fresh unsigned)
  world "${d}"
  tagged 1.2.3 unsigned
  admit "${d}" v1.2.3
  expect "${d}" 1 'the tag is not signed'
}

case_a_good_signature_over_sha1_is_refused() {
  local d object answer
  d=$(fresh sha1)
  world "${d}"
  tree_at 1.2.3
  TARGET=$(commit)
  object=$(tag_object v1.2.3 "${TARGET}" tag --digest-algo SHA1)
  ref v1.2.3 "${object}"
  answer=$(GNUPGHOME=${WORK}/keys/tag git -C "${PROJECT}" verify-tag --raw "${object}" 2>&1 || true) # gpg's status is the answer
  [[ ${answer} == *GOODSIG* ]] || fail 'the SHA-1 signature is not one gpg calls good without --weak-digest'
  admit "${d}" v1.2.3
  expect "${d}" 1 "the signature by ${TAG_SUBKEY} is refused: gpg cannot check it"
}

case_a_tag_carrying_two_signatures_is_refused() {
  local d object
  d=$(fresh two)
  world "${d}" tag stranger
  tree_at 1.2.3
  TARGET=$(commit)
  printf 'object %s\ntype commit\ntag v1.2.3\ntagger Probe <probe@example.invalid> %s +0000\n\nv1.2.3\n' "${TARGET}" "${TAGGED}" >"${d}/payload"
  g tag --faked-system-time "${SIGNED}" --yes --detach-sign --output "${d}/one.sig" "${d}/payload"
  g stranger --faked-system-time "${SIGNED}" --yes --detach-sign --output "${d}/two.sig" "${d}/payload"
  cat -- "${d}/one.sig" "${d}/two.sig" | g tag --enarmor | sed 's/ARMORED FILE-----$/SIGNATURE-----/' >"${d}/both.asc"
  cat -- "${d}/payload" "${d}/both.asc" >"${d}/object"
  object=$(git -C "${PROJECT}" hash-object -t tag -w -- "${d}/object")
  ref v1.2.3 "${object}"
  admit "${d}" v1.2.3
  expect "${d}" 1 "the tag's signature is not one OpenPGP signature"
}

case_a_lightweight_tag_or_a_tag_of_a_tree_is_refused() {
  local d object tree_id
  d=$(fresh lightweight)
  world "${d}"
  tree_at 1.2.3
  TARGET=$(commit)
  ref v1.2.3 "${TARGET}"
  admit "${d}" v1.2.3
  expect "${d}" 1 'the tag v1.2.3 names a commit, not a signed tag object'
  d=$(fresh tree_tag)
  world "${d}"
  tree_at 1.2.3
  TARGET=$(commit)
  tree_id=$(git -C "${PROJECT}" rev-parse 'HEAD^{tree}')
  object=$(KIND=tree tag_object v1.2.3 "${tree_id}" tag)
  ref v1.2.3 "${object}"
  admit "${d}" v1.2.3
  expect "${d}" 1 'the tag object tags a tree'
}

case_a_tag_object_of_another_name_or_header_is_refused() {
  local d object
  d=$(fresh other_name)
  world "${d}"
  tree_at 9.9.9
  TARGET=$(commit)
  object=$(tag_object v1.0.0 "${TARGET}" tag)
  ref v9.9.9 "${object}"
  admit "${d}" v9.9.9
  expect "${d}" 1 'the tag object is v1.0.0, pushed as v9.9.9'
  d=$(fresh header)
  world "${d}"
  tree_at 1.2.3
  TARGET=$(commit)
  printf 'object %s\ntype commit\ntag v1.2.3\ntag v0.0.1\ntagger Probe <probe@example.invalid> %s +0000\n\nv1.2.3\n' "${TARGET}" "${TAGGED}" >"${d}/payload"
  g tag --faked-system-time "${SIGNED}" --yes --armor --detach-sign --output "${d}/payload.asc" "${d}/payload"
  cat -- "${d}/payload" "${d}/payload.asc" >"${d}/object"
  object=$(git -C "${PROJECT}" hash-object -t tag -w --literally -- "${d}/object")
  ref v1.2.3 "${object}"
  admit "${d}" v1.2.3
  expect "${d}" 1 "the tag object's header is not git's"
}

case_a_tag_of_another_commit_than_the_runs_is_refused() {
  local d
  d=$(fresh other_commit)
  world "${d}"
  tagged 1.2.3 tag
  SHA_OVER=$(printf '%040d' 4) admit "${d}" v1.2.3
  expect "${d}" 1 "the tag names ${TARGET}, and this run is at 0000000000000000000000000000000000000004"
}

case_a_commit_off_mains_first_parent_line_is_refused() {
  local d object
  d=$(fresh side)
  world "${d}"
  tree_at 1.2.3
  commit >/dev/null
  git -C "${PROJECT}" checkout --quiet -b side
  write crates/probe-a/src/lib.rs '// side'
  TARGET=$(commit)
  git -C "${PROJECT}" checkout --quiet main
  git -C "${PROJECT}" -c user.name=Probe -c user.email=probe@example.invalid merge --quiet --no-ff --no-gpg-sign -m merge side
  object=$(tag_object v1.2.3 "${TARGET}" tag)
  ref v1.2.3 "${object}"
  admit "${d}" v1.2.3
  expect "${d}" 1 "${TARGET} is not on the first-parent line of the project's main"
}

case_a_run_other_than_a_v_tags_push_is_refused() {
  local d tag
  d=$(fresh not_push)
  world "${d}"
  tagged 1.2.3 tag
  EVENT_OVER=workflow_dispatch admit "${d}" v1.2.3
  expect "${d}" 1 "a release runs on a tag's push, and this run is a workflow_dispatch"
  for tag in 1.2.3 v1.2 v01.2.3 v1.2.3-01 v1.2.3-; do
    admit "${d}" "${tag}"
    expect "${d}" 1 "${tag} is not v and a semantic version"
  done
}

# A version with build metadata is refused, though it is a semantic version and its tree agrees.
case_a_version_with_build_metadata_is_refused() {
  local d
  d=$(fresh build_metadata)
  world "${d}"
  tagged 1.2.3+build.1 tag
  admit "${d}" v1.2.3+build.1
  expect "${d}" 1 "v1.2.3+build.1 carries build metadata (+build.1), which a release's version does not take"
}

case_a_version_below_the_projects_first_version_is_refused() {
  local d
  d=$(fresh first)
  world "${d}"
  catalogue_edit "${d}" '.projects.probe.first_version = "1.3.0"'
  tagged 1.2.3 tag
  admit "${d}" v1.2.3
  expect "${d}" 1 'v1.2.3 is below the project'"'"'s first_version 1.3.0'
  d=$(fresh first_pre)
  world "${d}"
  catalogue_edit "${d}" '.projects.probe.first_version = "1.2.3"'
  tagged 1.2.3-alpha.1 tag
  admit "${d}" v1.2.3-alpha.1
  expect "${d}" 1 'v1.2.3-alpha.1 is below'
}

case_a_project_without_a_signing_key_or_its_id_is_refused() {
  local d
  d=$(fresh no_key)
  world "${d}"
  catalogue_edit "${d}" '.projects.probe.signing_key = null'
  tagged 1.2.3 tag
  admit "${d}" v1.2.3
  expect "${d}" 1 'holds no signing_key for shuwariafrica/probe'
  d=$(fresh other_id)
  world "${d}"
  catalogue_edit "${d}" '.projects.probe.repository_id = 77'
  tagged 1.2.3 tag
  admit "${d}" v1.2.3
  expect "${d}" 1 "is repository ${ID}, which public-crates' projects.json does not name"
}

case_public_crates_unread_leaves_it_undecided() {
  local d
  d=$(fresh unread)
  world "${d}"
  tagged 1.2.3 tag
  mv -- "${d}/git/shuwariafrica/public-crates" "${d}/elsewhere"
  admit "${d}" v1.2.3
  expect "${d}" 75 "public-crates' main cannot be read"
}

case_release_ymls_actions_off_the_releases_commits_are_refused() {
  local d
  d=$(fresh pins)
  world "${d}"
  tree_at 1.2.3
  release_yml "${PROJECT}/.github/workflows/release.yml" ".jobs.package.steps[1].uses = \"shuwariafrica/.github/actions/crate-package@${COMMIT_OFF}\""
  again "${d}"
  expect "${d}" 1 "crate-package@${COMMIT_OFF} is not at ${OWN}"
  release_yml "${PROJECT}/.github/workflows/release.yml" '.jobs.verify.steps += [{"uses": "someone/evil@1234567890123456789012345678901234567890"}]'
  again "${d}"
  expect "${d}" 1 'someone/evil@1234567890123456789012345678901234567890 is not on'
}

# release.yml is the project's lifted template exactly, before anything is built: a step the
# template does not hold is refused here, as crate-sign and crate-publish refuse it again.
case_a_release_yml_holding_anything_the_template_does_not_is_refused_before_any_build() {
  local d
  d=$(fresh lifted)
  world "${d}"
  tree_at 1.2.3
  sed -i 's|^\(      - uses: actions/checkout@.*\)$|\1\n      - run: printenv|' "${PROJECT}/.github/workflows/release.yml"
  grep -qx '      - run: printenv' "${PROJECT}/.github/workflows/release.yml" || fail 'the step was not added'
  again "${d}"
  expect "${d}" 1 "release.yml is not public-crates' template at its gate-commit ${GATE}"
  expect "${d}" 1 'line 20 is [      - run: printenv], and the template makes it [      - uses: shuwariafrica/.github/actions/crate-package@'
}

case_verify_on_other_platforms_than_the_projects_is_refused() {
  local d
  d=$(fresh platforms)
  world "${d}"
  tree_at 1.2.3
  release_yml "${PROJECT}/.github/workflows/release.yml" '.jobs.verify.strategy.matrix.include += [{"platform": "windows-x64", "runner": "windows-2025-vs2026"}]'
  again "${d}"
  expect "${d}" 1 "release.yml's verify runs on"
  catalogue_edit "${d}" '.projects.probe.platforms = ["linux-x64", "windows-x64"]'
  release_yml "${PROJECT}/.github/workflows/release.yml"
  sed -i 's|^            runner: ubuntu-26.04$|&\n          - platform: windows-x64\n            runner: windows-2025-vs2026|' \
    "${PROJECT}/.github/workflows/release.yml"
  grep -qx '          - platform: windows-x64' "${PROJECT}/.github/workflows/release.yml" || fail 'the platform was not written'
  again "${d}"
  admitted "${d}"
  release_yml "${PROJECT}/.github/workflows/release.yml" '.jobs.verify.strategy.matrix.include += [{"platform": "windows-x64", "runner": "ubuntu-26.04"}]'
  again "${d}"
  expect "${d}" 1 "release.yml's verify runs on"
}

case_a_version_unlike_the_tags_is_refused() {
  local d
  d=$(fresh version)
  world "${d}"
  tree_at 1.2.4
  again "${d}"
  expect "${d}" 1 'probe-a is version 1.2.4, and the tag is v1.2.3'
}

case_a_crate_outside_the_projects_list_is_refused_and_an_unpublished_member_is_not_one() {
  local d
  d=$(fresh crates)
  world "${d}"
  tree_at 1.2.3
  write crates/probe-c/Cargo.toml '[package]
name = "probe-c"
version.workspace = true
edition = "2024"
'
  again "${d}"
  expect "${d}" 1 "the publishable crates are [probe-a, probe-b, probe-c], and the project's are [probe-a, probe-b]"
  write crates/probe-c/Cargo.toml '[package]
name = "probe-c"
version.workspace = true
edition = "2024"
publish = false
'
  again "${d}"
  admitted "${d}"
}

# A crate's manifest gives what crates.io refuses a crate without: a description that is not empty,
# and a license or a license-file, its own or the workspace's.
case_a_crate_without_a_description_or_a_licence_is_refused() {
  local d manifest
  d=$(fresh metadata)
  world "${d}"
  manifest=crates/probe-b/Cargo.toml
  tree_at 1.2.3
  sed -i '/^description = /d' "${PROJECT}/${manifest}"
  again "${d}"
  expect "${d}" 1 "probe-b's manifest gives no description, and crates.io refuses a crate without one"
  tree_at 1.2.3
  sed -i 's/^description = .*/description = ""/' "${PROJECT}/${manifest}"
  again "${d}"
  expect "${d}" 1 "probe-b's manifest gives no description"
  tree_at 1.2.3
  sed -i '/^license.workspace = true$/d' "${PROJECT}/${manifest}"
  again "${d}"
  expect "${d}" 1 "probe-b's manifest gives neither license nor license-file, and crates.io refuses a crate without one"
  sed -i '/^description = /a license-file = "LICENSE"' "${PROJECT}/${manifest}"
  grep -qx 'license-file = "LICENSE"' "${PROJECT}/${manifest}" || fail 'license-file was not written'
  again "${d}"
  admitted "${d}"
  tree_at 1.2.3
  sed -i '/^license = /d' "${PROJECT}/Cargo.toml"
  again "${d}"
  expect "${d}" 1 "probe-a's manifest gives neither license nor license-file"
}

case_any_cargo_configuration_but_the_roots_two_keys_is_refused() {
  local d
  d=$(fresh config)
  world "${d}"
  tree_at 1.2.3
  write .cargo/config.toml '[build]
rustc-wrapper = "/bin/true"
'
  again "${d}"
  expect "${d}" 1 '.cargo/config.toml: sets build.rustc-wrapper'
  tree_at 1.2.3
  write crates/probe-a/.cargo/config.toml ''
  again "${d}"
  expect "${d}" 1 "crates/probe-a/.cargo/config.toml: a cargo configuration other than the root's .cargo/config.toml"
}

case_a_lock_naming_a_git_source_is_refused() {
  local d
  d=$(fresh git_source)
  world "${d}"
  tree_at 1.2.3
  write Cargo.lock 'version = 4

[[package]]
name = "windows"
version = "0.62.0"
source = "git+https://github.com/microsoft/windows-rs?rev=0123456789abcdef0123456789abcdef01234567#0123456789abcdef0123456789abcdef01234567"
'
  again "${d}"
  expect "${d}" 1 'Cargo.lock takes windows from git+https://github.com/microsoft/windows-rs'
}

case_a_rust_toolchain_file_or_a_toolchain_with_a_path_or_no_exact_release_is_refused() {
  local d channel
  d=$(fresh toolchain)
  world "${d}"
  tree_at 1.2.3
  write crates/probe-b/rust-toolchain 'nightly
'
  again "${d}"
  expect "${d}" 1 'crates/probe-b/rust-toolchain is a rust-toolchain file'
  tree_at 1.2.3
  write rust-toolchain.toml '[toolchain]
channel = "1.99.1"
path = "/opt/rust"
'
  again "${d}"
  expect "${d}" 1 'rust-toolchain.toml names a path'
  for channel in stable 1.99 nightly-2026-11-01; do
    write rust-toolchain.toml "[toolchain]
channel = \"${channel}\"
"
    again "${d}"
    expect "${d}" 1 "rust-toolchain.toml names \"${channel}\", not one exact release"
  done
}

case_the_dependency_order_puts_each_crate_after_those_it_depends_on() {
  local d
  d=$(fresh order)
  world "${d}"
  tree_at 1.2.3
  write crates/probe-a/Cargo.toml '[package]
name = "probe-a"
version.workspace = true
edition = "2024"
description = "The first probe."
license.workspace = true

[dependencies]
probe-b = { path = "../probe-b", version = "1.2.3" }
'
  write crates/probe-b/Cargo.toml '[package]
name = "probe-b"
version.workspace = true
edition = "2024"
description = "The second probe."
license.workspace = true
'
  again "${d}"
  admitted "${d}"
  out_is "${d}" crates '["probe-b","probe-a"]'
}

crates_main "$@"
