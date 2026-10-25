#!/bin/bash
# Reports repo sizes via the GitHub API instead of cloning/pulling.
# Each API call is tiny JSON (~1-2 KB), so total data used is minimal
# compared to actually cloning/pulling every repo.

USERNAME="niyid"

# Optional but recommended: set a GitHub token to avoid the 60 req/hr
# unauthenticated rate limit (authenticated = 5000 req/hr).
# export GITHUB_TOKEN="ghp_xxx..."

REPOS=(
  channel
  cofo
  textimania
  npc
  moneroodoo
  ogbojuode
  irekeonibudo
  ogbojuode-gdm
  irekeonibudo-gdm
  ogbojuode-3d
  macrotrack
  kabu-kabu-p2p
  bitchat-android
  aerosys
  funtomo
  thoth-android-ai
  kabu-kabu-p2p
  cbt_verification_system
  cryptolender
  payment_monero_rpc
  cryptofindr
  coreader
  buzzr
  readers-riddle-android
  favornet2
  scrowit
  im_alive_pension
  hr_payroll_nigerian_state
  android-imalive
  airline-manager-app
  aviation-manager-app
  channel-app
  cofo-app
  farmprod-app
  fidelity-visarecon-app
  npc-app
  textimania-app
  vasworks-util
  payroll-app
  ibedc-app
  readers-riddle
  server_extras
  buzzr_extra
)

TOTAL_KB=0
echo "Checking repo sizes for $USERNAME via GitHub API (no clone/pull performed)..."
echo "-------------------------------------------------------------------------"
printf "%-35s %12s\n" "REPO" "SIZE"

for repo in "${REPOS[@]}"; do
  echo "  -> querying $repo..." >&2
  if [ -n "$GITHUB_TOKEN" ]; then
    RESPONSE=$(curl -s --connect-timeout 5 --max-time 15 \
      -H "Authorization: token $GITHUB_TOKEN" \
      "https://api.github.com/repos/$USERNAME/$repo")
  else
    RESPONSE=$(curl -s --connect-timeout 5 --max-time 15 \
      "https://api.github.com/repos/$USERNAME/$repo")
  fi

  if [ -z "$RESPONSE" ]; then
    printf "%-35s %12s  %s\n" "$repo" "N/A" "curl timed out / no response"
    continue
  fi

  # 'size' field from GitHub API is in KB (this is the size of the
  # bare repo on GitHub's side, which approximates a fresh clone;
  # an incremental `git pull` would usually use less than this).
  SIZE_KB=$(echo "$RESPONSE" | grep -o '"size": *[0-9]*' | head -1 | grep -o '[0-9]*')

  if [ -z "$SIZE_KB" ]; then
    # Repo not found, private without auth, or rate-limited
    MSG=$(echo "$RESPONSE" | grep -o '"message": *"[^"]*"' | head -1)
    printf "%-35s %12s  %s\n" "$repo" "N/A" "$MSG"
    continue
  fi

  TOTAL_KB=$((TOTAL_KB + SIZE_KB))

  if [ "$SIZE_KB" -ge 1024 ]; then
    SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $SIZE_KB/1024}")
    printf "%-35s %10s MB\n" "$repo" "$SIZE_MB"
  else
    printf "%-35s %10s KB\n" "$repo" "$SIZE_KB"
  fi
done

echo "-------------------------------------------------------------------------"
TOTAL_MB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_KB/1024}")
echo "Approximate total (full clone equivalent): ${TOTAL_KB} KB (~${TOTAL_MB} MB)"
echo ""
echo "Note: this is the repo size GitHub reports (roughly what a fresh"
echo "'git clone' would transfer). A 'git pull' on a repo you already"
echo "have locally usually transfers far less — only the new commits/objects."
