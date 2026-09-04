#!/usr/bin/env bash
set -euo pipefail

# Sync all forks owned by the authenticated user with their upstream parents.
# Usage:
#   ./sync-all-forks.sh           # actually perform sync (when run locally or in Actions with PAT)
#   ./sync-all-forks.sh --dry-run # only list what would run
#
# Environment:
#   MAX_REPOS - optional limit on how many repos to process in one run (0 = no limit)
#
# Requirements (for local runs):
#   - gh (GitHub CLI) authenticated (gh auth login OR gh auth login --with-token)
#   - git
#   - jq

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; fi

MAX_REPOS=${MAX_REPOS:-0}

echo "Checking gh authentication..."
USER=$(gh api user --jq .login) || { echo "gh not authenticated. Run: gh auth login"; exit 1; }
echo "Authenticated as: $USER"

LIMIT=1000

echo "Listing forks for $USER..."
repos_json=$(gh repo list "$USER" --limit "$LIMIT" --json name,url,sshUrl,isFork,parent,defaultBranchRef) || {
  echo "Failed to list repos via gh. Exiting."; exit 1;
}

count=0

# Iterate over forks
echo "$repos_json" | jq -c '.[] | select(.isFork) | {name: .name, clone: .url, ssh: .sshUrl, parent_full:.parent.nameWithOwner, parent_clone:.parent.url, branch:.defaultBranchRef.name }' \
| while read -r repo; do
  name=$(jq -r .name <<<"$repo")
  clone=$(jq -r .clone <<<"$repo")
  parent_clone=$(jq -r .parent_clone <<<"$repo")
  branch=$(jq -r .branch <<<"$repo")

  count=$((count+1))
  if [ "$MAX_REPOS" -ne 0 ] && [ "$count" -gt "$MAX_REPOS" ]; then
    echo "Reached MAX_REPOS ($MAX_REPOS). Stopping."
    break
  fi

  echo
  echo "==== $name (branch: $branch) ===="
  echo "Fork clone URL: $clone"
  echo "Upstream clone URL: $parent_clone"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry-run) skipping actual clone/merge"
    continue
  fi

  tmp=$(mktemp -d)
  echo "Cloning $name (branch $branch)..."
  if ! git clone --depth=1 --branch "$branch" "$clone" "$tmp/$name"; then
    echo "  Failed to clone $clone. Skipping."
    rm -rf "$tmp"
    continue
  fi

  pushd "$tmp/$name" >/dev/null
  git remote add upstream "$parent_clone" || true
  echo "  Fetching upstream/$branch..."
  if ! git fetch upstream "$branch" --depth=1; then
    echo "  Failed to fetch upstream branch. Skipping."
    popd >/dev/null
    rm -rf "$tmp"
    continue
  fi

  git checkout "$branch"

  echo "  Attempting fast-forward merge from upstream/$branch..."
  if git merge --ff-only "upstream/$branch"; then
    echo "  Fast-forwarded."
    git push origin "$branch"
    echo "  Pushed to origin/$branch."
  else
    echo "  Not fast-forwardable; attempting regular merge (may create merge commit)."
    if git merge --no-edit "upstream/$branch"; then
      git push origin "$branch"
      echo "  Merged and pushed."
    else
      echo "  Merge produced conflicts. Aborting merge and skipping $name."
      git merge --abort || true
      # Optionally: create a PR for manual resolution. Skipping for safety.
    fi
  fi

  popd >/dev/null
  rm -rf "$tmp"
done

echo
echo "Done."
