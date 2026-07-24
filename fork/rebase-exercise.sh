#!/usr/bin/env bash
# Disposable proof that the monthly train can carry the functional patch from
# the previous upstream pin to the current one and keep its integration suite
# green. Nothing in the caller's branch or worktree is rewritten.
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "${script_dir}/.." && pwd)"
readonly old_ref="${1:-refs/tags/v1.40.1}"
readonly new_ref="${2:-refs/tags/v1.41.0}"
readonly temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/aldehyde-rebase-exercise.XXXXXX")"
readonly exercise_tree="${temporary_root}/worktree"

info() { printf '\033[1;36m==\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  git -C "${repo_root}" worktree remove --force "${exercise_tree}" >/dev/null 2>&1 || true
  case "${temporary_root}" in
    "${TMPDIR:-/tmp}"/aldehyde-rebase-exercise.*)
      rm -rf -- "${temporary_root}"
      ;;
    *)
      printf 'refusing to remove unexpected temporary path: %s\n' "${temporary_root}" >&2
      ;;
  esac
}
trap cleanup EXIT

cd "${repo_root}"
[[ -z "$(git status --porcelain)" ]] \
  || die 'source worktree must be clean so the exercise uses committed fork state only'

git remote get-url upstream >/dev/null 2>&1 \
  || git remote add upstream https://github.com/logto-io/logto.git
info 'Fetch the old and current upstream tags'
git fetch --force --tags upstream

old_commit="$(git rev-parse "${old_ref}^{commit}")"
new_commit="$(git rev-parse "${new_ref}^{commit}")"
functional_commit="$(git log --format=%H --grep='^feat(core): boot-seed logto-operator M2M credential on startup$' -1 "${new_commit}..HEAD")"
[[ -n "${functional_commit}" ]] || die 'could not locate the isolated functional patch commit'

info "Materialize old monthly pin ${old_ref} (${old_commit})"
git worktree add --detach "${exercise_tree}" "${old_commit}" >/dev/null

info 'Apply the isolated functional patch to the old pin'
git -C "${exercise_tree}" cherry-pick "${functional_commit}"

info "Replay that old-pin patch onto ${new_ref} (${new_commit})"
git -C "${exercise_tree}" rebase --onto "${new_commit}" "${old_commit}" HEAD

replayed_commit="$(git -C "${exercise_tree}" rev-parse HEAD)"
[[ "$(git -C "${exercise_tree}" rev-parse HEAD^)" == "${new_commit}" ]] \
  || die 'the replay did not produce exactly one functional commit on the current pin'
git diff --exit-code "${functional_commit}^{tree}" "${replayed_commit}^{tree}" >/dev/null \
  || die 'the old-pin to current-pin replay changed the functional patch result'

info 'Attach the current committed fork harness to the disposable replay'
git archive HEAD fork/harness | tar -x -C "${exercise_tree}"

info 'Install the replay worktree and build the patched CLI/core'
(
  cd "${exercise_tree}"
  pnpm install --frozen-lockfile
  pnpm --filter '@logto/cli...' --filter '@logto/core...' build
)

info 'Run the real-Postgres boot-seed suite on the replayed patch'
(
  cd "${exercise_tree}"
  bash fork/harness/run.sh
)

info "REBASE EXERCISE PASSED: ${old_ref} -> ${new_ref}"
info "replayed functional commit: ${replayed_commit}"
