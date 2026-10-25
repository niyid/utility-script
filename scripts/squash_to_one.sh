#!/bin/bash

# Usage: git-squash-branch /path/to/repo [base-branch] [num-commits]

REPO_PATH="$1"
BASE_BRANCH="${2:-main}"
COMMITS_TO_SQUASH="$3"

if [ -z "$REPO_PATH" ]; then
    echo "Usage: git-squash-branch /path/to/repo [base-branch] [num-commits]"
    exit 1
fi

# Ensure repo exists
if [ ! -d "$REPO_PATH/.git" ]; then
    echo "❌ '$REPO_PATH' is not a Git repository."
    exit 1
fi

cd "$REPO_PATH" || exit 1

# Ensure clean working directory
if [ -n "$(git status --porcelain)" ]; then
    echo "❌ Working directory not clean. Commit or stash changes first."
    exit 1
fi

# Fetch latest refs
git fetch origin

# Get current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ]; then
    echo "❌ You are on the base branch '$BASE_BRANCH'. Switch to a feature branch."
    exit 1
fi

# Determine commits to squash if not provided
if [ -z "$COMMITS_TO_SQUASH" ]; then
    COMMITS_TO_SQUASH=$(git rev-list --count "$BASE_BRANCH..$CURRENT_BRANCH")
fi

if [ "$COMMITS_TO_SQUASH" -eq 0 ]; then
    echo "✅ Nothing to squash. '$CURRENT_BRANCH' is up to date with '$BASE_BRANCH'."
    exit 0
fi

echo "📦 Squashing last $COMMITS_TO_SQUASH commit(s) on '$CURRENT_BRANCH'..."

# Do the interactive rebase automatically
GIT_SEQUENCE_EDITOR="sed -i -e '2,${COMMITS_TO_SQUASH}s/^pick/squash/'" git rebase -i "$BASE_BRANCH"

if [ $? -ne 0 ]; then
    echo "❌ Rebase failed. Resolve conflicts and run: git rebase --continue"
    exit 1
fi

# Confirm force push
read -p "✅ Rebase complete. Push to origin/$CURRENT_BRANCH with --force? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    git push --force-with-lease
    echo "🚀 Force-pushed to origin/$CURRENT_BRANCH"
else
    echo "ℹ️ Skipping push. You can push manually:"
    echo "   git push --force-with-lease"
fi
