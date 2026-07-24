#!/usr/bin/env bash
# Monthly upstream rebase for the aldehyde.logto fork.
#
# The fork carries a single functional commit (the logto-operator boot-seed)
# plus fork-only tooling on top of a pinned upstream Logto tag recorded in
# fork/UPSTREAM_REF. This script moves those fork commits onto a newer upstream
# tag, then rebuilds and re-runs the integration harness so a rebase is never
# declared done until the patch still passes.
#
# Usage:
#   fork/rebase.sh <new-upstream-ref>     # e.g. v1.42.0 or refs/tags/v1.42.0
#   fork/rebase.sh --dry-run <new-ref>    # fetch + show what would move, no rebase
#
# Cadence: run monthly. Pick the newest upstream stable tag that is >= the
# current pin. Resolve conflicts inside packages/core/src/boot-seed and
# packages/core/src/index.ts (the only files the functional patch touches).
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "${script_dir}/.." && pwd)"
readonly ref_file="${script_dir}/UPSTREAM_REF"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;36m==\033[0m %s\n' "$*"; }

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then dry_run=true; shift; fi
new_ref="${1:-}"
[[ -n "${new_ref}" ]] || die "usage: fork/rebase.sh [--dry-run] <new-upstream-ref>"
[[ "${new_ref}" == refs/* ]] || new_ref="refs/tags/${new_ref}"

# shellcheck source=/dev/null
source "${ref_file}"
[[ -n "${UPSTREAM_COMMIT:-}" ]] || die "UPSTREAM_COMMIT missing from ${ref_file}"

cd "${repo_root}"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean; commit or stash first"

info "Fetching upstream (${UPSTREAM_REMOTE})"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "${UPSTREAM_REMOTE}"
git fetch --tags upstream

old_commit="${UPSTREAM_COMMIT}"
new_commit="$(git rev-parse "${new_ref}^{commit}")"
info "current pin : ${UPSTREAM_REF} (${old_commit})"
info "target pin  : ${new_ref} (${new_commit})"

if [[ "${old_commit}" == "${new_commit}" ]]; then
  info "already on the target ref; nothing to do."
  exit 0
fi

info "Fork commits that will be replayed onto ${new_ref}:"
git --no-pager log --oneline "${old_commit}..HEAD"

if [[ "${dry_run}" == true ]]; then
  info "dry-run: showing merge-tree preview of the replay (no branch change)"
  git --no-pager range-diff "${old_commit}..HEAD" "${new_commit}..HEAD" 2>/dev/null || true
  info "dry-run complete; no rebase performed."
  exit 0
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
info "Rebasing ${branch}: --onto ${new_commit} ${old_commit}"
git rebase --onto "${new_commit}" "${old_commit}" "${branch}"

info "Recording new pin in ${ref_file}"
{
  echo "# Pinned upstream Logto ref this fork is rebased onto."
  echo "# Updated by fork/rebase.sh on each monthly rebase. Do not hand-edit the SHA."
  echo "UPSTREAM_REMOTE=${UPSTREAM_REMOTE}"
  echo "UPSTREAM_REF=${new_ref}"
  echo "UPSTREAM_COMMIT=${new_commit}"
} > "${ref_file}"
git add "${ref_file}"
git commit -m "chore(fork): rebase onto upstream ${new_ref#refs/tags/}" >/dev/null

info "Rebuilding patched package + deps"
pnpm --filter "@logto/cli..." --filter "@logto/core..." build

info "Re-running the boot-seed integration harness"
bash "${script_dir}/harness/run.sh"

info "Rebase onto ${new_ref#refs/tags/} complete and verified."
info "Review the new pin commit, then: git push origin ${branch}"
