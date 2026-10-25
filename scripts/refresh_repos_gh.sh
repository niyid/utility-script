#!/bin/bash
USERNAME="niyid"
echo "Refreshing repositories for user $USERNAME..."
REPOS=(
  guntrip
  funtomo
  moneroodoo
  ogbojuode
  irekeonibudo
  ogbojuode-gdx
  irekeonibudo-gdx
  ogbojuode-3d
  irekeonibudo-3d  
  macrotrack
  kabu-kabu-p2p
  thoth-android-ai
  kabu-kabu-p2p
)

TOTAL_KB=0

# Prints a KB value as KB or MB depending on size
format_size() {
  local kb=$1
  if [ "$kb" -ge 1024 ]; then
    awk -v kb="$kb" 'BEGIN { printf "%.2f MB", kb/1024 }'
  else
    echo "${kb} KB"
  fi
}

for repo in "${REPOS[@]}"; do
  echo "🔄 Processing $repo..."
  REPO_URL="https://github.com/$USERNAME/$repo.git"
  if [ -d "$repo" ]; then
    echo "📁 Repo $repo already exists. Pulling latest changes..."
    cd "$repo" || continue
    # Figure out the default branch this repo actually uses
    DEFAULT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
    if [ -z "$DEFAULT_BRANCH" ]; then
      DEFAULT_BRANCH="main"
    fi
    # Pull with an explicit merge strategy so it never hits the
    # "divergent branches" prompt, and autostash any local noise
    git pull --no-rebase --autostash origin "$DEFAULT_BRANCH" \
      || git pull --no-rebase --autostash origin main \
      || git pull --no-rebase --autostash origin master
  else
    echo "📥 Cloning $repo..."
    git clone "$REPO_URL"
    cd "$repo" || continue
  fi
  # Create or update a dummy file to simulate change
  echo "Refreshed at $(date)" > refresh.txt
  git add refresh.txt
  # Commit and push if there are changes
  if ! git diff --cached --quiet; then
    git commit -m "chore: refresh $(date '+%Y-%m-%d %H:%M:%S')"
    git push origin HEAD
  else
    echo "✅ No changes to commit in $repo."
  fi

  # Measure repo size (KB) and add to running total
  REPO_KB=$(du -sk . 2>/dev/null | cut -f1)
  TOTAL_KB=$((TOTAL_KB + REPO_KB))
  echo "📦 $repo size: $(format_size "$REPO_KB")"

  cd ..
done

echo ""
echo "✅ Done. Grand total size across all repos: $(format_size "$TOTAL_KB")"
