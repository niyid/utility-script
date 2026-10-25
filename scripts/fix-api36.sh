#!/usr/bin/env bash
# fix-api36.sh — target API 36, bump versions, verify, commit, push, clean up (ajo + scrowit)
#
# Usage:
#   bash fix-api36.sh                      # uses the default paths below
#   bash fix-api36.sh <ajo-root> <scrowit-root>   # optional overrides
#
# Default paths:
#   ajo      ~/git/ajo-android-p2p
#   scrowit  ~/git/scrowit-android-p2p
#
# Per project:
#   1. Removes untracked leftover *.bak files from an earlier run of this script
#   2. Aborts if the git working tree is dirty (override with ALLOW_DIRTY=1)
#   3. Backs up the two gradle files to ~/.api36-backups/<timestamp>/<project>/ (outside the repo)
#   4. app/build.gradle.kts : compileSdk 35 -> 36, targetSdk 35 -> 36, versionCode/versionName bumped
#      build.gradle.kts     : AGP 8.7.3 -> 8.9.1 (first AGP that officially supports compileSdk 36)
#   5. VERIFIES the edits (values, no stale 35 / 8.7.3 left, only those 2 files changed);
#      on failure it restores from backup and aborts
#   6. git add -A && git commit (multi-line message), then git push
#   7. Verifies the tree is clean and local HEAD matches the remote branch
#   8. Deletes the backups once everything above succeeded
#
# Versions:
#   ajo      13    / 0.1.3  -> 14    / 0.1.4
#   scrowit  10036 / 1.0.36 -> 10037 / 1.0.37

set -euo pipefail

AJO="${1:-$HOME/git/ajo-android-p2p}"
SCROWIT="${2:-$HOME/git/scrowit-android-p2p}"

AGP_NEW="8.9.1"
BACKUP_ROOT="$HOME/.api36-backups/$(date +%Y%m%d-%H%M%S)"

fail() { echo "ERROR: $*" >&2; exit 1; }

preflight() {
  local root="$1" old_code="$2" old_name="$3"
  local app="$root/app/build.gradle.kts" top="$root/build.gradle.kts"

  [[ -f "$app" ]] || fail "$app not found"
  [[ -f "$top" ]] || fail "$top not found"
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$root is not a git repository"

  # Leftover .bak files from an earlier run (untracked only)
  local f
  for f in "app/build.gradle.kts.bak" "build.gradle.kts.bak"; do
    if [[ -f "$root/$f" ]] && ! git -C "$root" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      rm -f "$root/$f"
      echo "Removed leftover $root/$f"
    fi
  done

  grep -q "versionCode = $old_code" "$app" || fail "$app does not contain versionCode = $old_code (already patched?)"
  grep -q "versionName = \"$old_name\"" "$app" || fail "$app does not contain versionName = \"$old_name\""
  if [[ -z "${ALLOW_DIRTY:-}" && -n "$(git -C "$root" status --porcelain)" ]]; then
    fail "$root has uncommitted changes; commit/stash them first (or run with ALLOW_DIRTY=1)"
  fi
}

verify_edit() {
  local root="$1" new_code="$2" new_name="$3"
  local app="$root/app/build.gradle.kts" top="$root/build.gradle.kts"
  local ok=1

  grep -qE "^\s*compileSdk = 36\s*$" "$app"                  || { echo "  FAIL compileSdk != 36"; ok=0; }
  grep -qE "^\s*targetSdk = 36\s*$" "$app"                   || { echo "  FAIL targetSdk != 36"; ok=0; }
  grep -qE "^\s*(compile|target)Sdk = 35" "$app"             && { echo "  FAIL stale SDK 35 remains"; ok=0; }
  grep -qE "^\s*versionCode = $new_code\s*$" "$app"          || { echo "  FAIL versionCode != $new_code"; ok=0; }
  grep -qE "^\s*versionName = \"$new_name\"\s*$" "$app"      || { echo "  FAIL versionName != $new_name"; ok=0; }
  grep -q "8\.7\.3" "$top"                                   && { echo "  FAIL stale AGP 8.7.3 remains"; ok=0; }
  # every com.android.* plugin line must carry the new AGP version
  local total good
  total=$(grep -cE 'id\("com\.android\.(application|library)"\)' "$top" || true)
  good=$(grep -cE "id\(\"com\.android\.(application|library)\"\).*version \"$AGP_NEW\"" "$top" || true)
  [[ "$total" -ge 1 && "$total" -eq "$good" ]]               || { echo "  FAIL AGP lines not all $AGP_NEW ($good/$total)"; ok=0; }
  # only the two expected files may differ from HEAD
  local changed
  changed=$(git -C "$root" status --porcelain | awk '{print $2}' | sort | tr '\n' ' ')
  [[ "$changed" == "app/build.gradle.kts build.gradle.kts " ]] || { echo "  FAIL unexpected changed files: $changed"; ok=0; }

  [[ $ok -eq 1 ]]
}

patch_project() {
  local root="$1" name="$2" old_code="$3" new_code="$4" old_name="$5" new_name="$6"
  local app="$root/app/build.gradle.kts" top="$root/build.gradle.kts"
  local bdir="$BACKUP_ROOT/$name"

  mkdir -p "$bdir"
  cp "$app" "$bdir/app.build.gradle.kts.bak"
  cp "$top" "$bdir/root.build.gradle.kts.bak"

  sed -i \
    -e 's/^\(\s*compileSdk = \)35/\136/' \
    -e 's/^\(\s*targetSdk = \)35/\136/' \
    -e "s/^\(\s*versionCode = \)$old_code/\1$new_code/" \
    -e "s/^\(\s*versionName = \)\"$old_name\"/\1\"$new_name\"/" \
    "$app"

  sed -i -E \
    "/id\(\"com\.android\.(application|library)\"\)/ s/version \"[0-9.]+\"/version \"$AGP_NEW\"/" \
    "$top"

  echo "== $root: verifying edits"
  if ! verify_edit "$root" "$new_code" "$new_name"; then
    cp "$bdir/app.build.gradle.kts.bak"  "$app"
    cp "$bdir/root.build.gradle.kts.bak" "$top"
    fail "verification failed for $name; originals restored (backups kept in $bdir)"
  fi
  grep -nE "compileSdk|targetSdk|versionCode|versionName = \"" "$app" | grep -v Suffix
  grep -n "com.android" "$top"
  echo "  OK"

  git -C "$root" add -A && git -C "$root" commit \
-m "Target API 36 and bump version to $new_name ($new_code)" \
-m "Google Play requires apps to target at least API level 36.
Play Console flagged version code $old_code as targeting API 35.

Changes:
- compileSdk 35 -> 36
- targetSdk 35 -> 36
- versionCode $old_code -> $new_code
- versionName $old_name -> $new_name
- Android Gradle Plugin 8.7.3 -> $AGP_NEW (first release that officially
  supports compileSdk 36; compatible with the existing Gradle 8.11.1 wrapper)

Behaviour-change review for targetSdk 36:
- Edge-to-edge opt-out is not used, so no change
- Predictive back: activities use OnBackPressedCallback, so no change
- Orientation/resizability restrictions are ignored on screens >= 600dp"

  if ! git -C "$root" push; then
    echo "No upstream configured; pushing with -u origin HEAD" >&2
    git -C "$root" push -u origin HEAD
  fi

  # Post-push verification: clean tree and remote matches local HEAD
  [[ -z "$(git -C "$root" status --porcelain)" ]] || fail "$name: working tree not clean after commit"
  [[ "$(git -C "$root" rev-parse HEAD)" == "$(git -C "$root" rev-parse '@{u}')" ]] \
    || fail "$name: local HEAD does not match remote after push"
  echo "  committed + pushed ($(git -C "$root" rev-parse --short HEAD)), tree clean"

  rm -rf "$bdir"
}

# Check both projects before touching either
preflight "$AJO"     13    "0.1.3"
preflight "$SCROWIT" 10036 "1.0.36"

patch_project "$AJO"     "ajo"     13    14    "0.1.3"  "0.1.4"
patch_project "$SCROWIT" "scrowit" 10036 10037 "1.0.36" "1.0.37"

rmdir "$BACKUP_ROOT" 2>/dev/null || true
rmdir "$HOME/.api36-backups" 2>/dev/null || true
echo
echo "All done: edits verified, pushed, backups deleted."
echo "Next: ./gradlew clean :app:bundleRelease in each project"
