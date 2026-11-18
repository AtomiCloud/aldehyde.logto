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
# current pin. Resolve conflicts inside packages/core/src/boot-seed,
# packages/core/src/index.ts and packages/experience/src/shared/components/LogtoSignature
# (plus its unit test packages/account/src/App.branding.test.tsx): the only files the
# two functional patches touch; the fork also scopes .github/workflows/commitlint.yml
# to its own commits.
#
# The replay rewrites the branch, but the script ends it with a `merge -s ours` of
# the replaced history, so the fork branch only ever fast-forwards. Never force-push:
# push the result as a NEW branch and open a PR into the fork branch.
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

# Only commits that descend from the current pin (--ancestry-path): a previous rebase
# landed through a `merge -s ours` of the history it replaced (no force-push), and the
# PR may then land through a GitHub merge commit whose FIRST parent is that replaced
# history. Those replaced commits do not contain the pin, so they are never replayed;
# fork commits merged later from feature branches on top of the pin still are.
mapfile -t fork_commits < <(git rev-list --reverse --topo-order --no-merges --ancestry-path "${old_commit}..HEAD")
[[ "${#fork_commits[@]}" -gt 0 ]] || die "no fork commits found on top of ${old_commit}"
info "Fork commits that will be replayed onto ${new_ref}:"
git --no-pager log --oneline --no-walk=unsorted "${fork_commits[@]}"

if [[ "${dry_run}" == true ]]; then
  info "dry-run: replay preview in a throwaway worktree (no branch change)"
  preview="$(mktemp -d "${TMPDIR:-/tmp}/aldehyde-rebase-preview.XXXXXX")"
  git worktree add --detach "${preview}" "${new_commit}" >/dev/null
  if git -C "${preview}" -c commit.gpgsign=false cherry-pick "${fork_commits[@]}" >/dev/null 2>&1; then
    info "dry-run: every fork commit replays cleanly onto ${new_ref}"
  else
    info "dry-run: the replay CONFLICTS; resolve inside the files listed in the header"
    git -C "${preview}" cherry-pick --abort >/dev/null 2>&1 || true
  fi
  git worktree remove --force "${preview}"
  info "dry-run complete; no rebase performed."
  exit 0
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
old_head="$(git rev-parse HEAD)"
info "Replaying ${#fork_commits[@]} fork commits of ${branch} onto ${new_commit}"
info "(previous head ${old_head}; on a conflict resolve, git cherry-pick --continue, then"
info " re-run the remaining steps of this script by hand)"
git checkout -q -B "${branch}" "${new_commit}"
git cherry-pick "${fork_commits[@]}"

info "Recording new pin in ${ref_file}"
{
  echo "# Pinned upstream Logto ref this fork is rebased onto."
  echo "# Updated by fork/rebase.sh on each monthly rebase. Do not hand-edit the SHA."
  echo "UPSTREAM_REMOTE=${UPSTREAM_REMOTE}"
  echo "UPSTREAM_REF=${new_ref}"
  echo "UPSTREAM_COMMIT=${new_commit}"
} > "${ref_file}"
git add "${ref_file}"
# No scope: upstream commitlint only accepts its own package scopes.
git commit -m "chore: rebase fork onto upstream ${new_ref#refs/tags/}" >/dev/null

# Land without a force-push: record the replaced history as the second parent of
# an `ours` merge. The tree stays exactly the replayed one, and the fork branch can
# fast-forward to this commit through a normal PR.
info "Superseding the previous fork history ${old_head} (merge -s ours, tree unchanged)"
git merge -q -s ours --no-edit \
  -m "chore: supersede the fork history before upstream ${new_ref#refs/tags/}" "${old_head}"

info "Installing dependencies of the new pin"
pnpm install --frozen-lockfile

info "Rebuilding patched package + deps"
pnpm --filter "@logto/cli..." --filter "@logto/core..." build

info "Re-running the boot-seed integration harness"
bash "${script_dir}/harness/run.sh"

info "Rebase onto ${new_ref#refs/tags/} complete and verified."
info "Review the new pin commit, then push it as a new branch and open a PR (no force-push)."
