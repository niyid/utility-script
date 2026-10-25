#!/bin/bash

# Rebuild all projects using gapsb (bundlePlaystoreRelease).
#
# For each project, in order:
#   1. Patch EmbeddedI2PRouter.kt (multi-mirror reseed fix) — idempotent
#   2. Build with Gradle
#   3. On success: bump versionCode + versionName patch, then git commit & push
#
# Usage: ./rebuild_all.sh
#
# Note: gapsb is defined as a ~/.bashrc alias and cannot be sourced in
# non-interactive shells (bashrc exits early). The command is inlined here.

PROJECTS=(
    "/home/niyid/git/ajo-android-p2p"
)

# ── Signing / environment params (mirrors gapsb alias in ~/.bashrc) ──────────
KEY_ALIAS="${VERZUS_KEY_ALIAS:-key0}"
KEY_PASSWORD="${VERZUS_KEY_PASSWORD:-Ps-ef1986}"
KEYSTORE="${VERZUS_KEYSTORE:-/home/niyid/git/server_extras/techducat.jks}"
STORE_PASSWORD="${VERZUS_STORE_PASSWORD:-Ps-ef1986}"

# ── Helper scripts ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_SCRIPT="${PATCH_RESEED:-$SCRIPT_DIR/patch_reseed.py}"
BUMP_SCRIPT="${BUMP_VERSION:-$SCRIPT_DIR/bump_version.py}"

for tool in "$PATCH_SCRIPT" "$BUMP_SCRIPT"; do
    if [ ! -f "$tool" ]; then
        echo "ERROR: required script not found: $tool"
        echo "       Place patch_reseed.py and bump_version.py next to rebuild_all.sh"
        echo "       or set PATCH_RESEED / BUMP_VERSION env vars to their paths."
        exit 1
    fi
done

TOTAL=${#PROJECTS[@]}
PASS=0
FAIL=0
FAILED_PROJECTS=()

BUILD_DATE="$(date +%Y-%m-%d)"

echo "=============================================="
echo "  Rebuilding $TOTAL projects (bundlePlaystoreRelease)"
echo "  Date: $BUILD_DATE"
echo "  Patch script: $PATCH_SCRIPT"
echo "  Bump script:  $BUMP_SCRIPT"
echo "=============================================="
echo ""

for PROJECT in "${PROJECTS[@]}"; do
    PROJECT_NAME=$(basename "$PROJECT")
    echo "----------------------------------------------"
    echo "  [$((PASS + FAIL + 1))/$TOTAL] Building: $PROJECT_NAME"
    echo "----------------------------------------------"

    if [ ! -d "$PROJECT" ]; then
        echo "  ✗ ERROR: Directory not found: $PROJECT"
        FAIL=$((FAIL + 1))
        FAILED_PROJECTS+=("$PROJECT_NAME (directory not found)")
        echo ""
        continue
    fi

    cd "$PROJECT" || {
        echo "  ✗ ERROR: Could not enter directory: $PROJECT"
        FAIL=$((FAIL + 1))
        FAILED_PROJECTS+=("$PROJECT_NAME (cd failed)")
        echo ""
        continue
    }

    # ── 1. Apply reseed patch ─────────────────────────────────────────────────
    echo "  [1/3] Patching EmbeddedI2PRouter.kt..."
    if ! python3 "$PATCH_SCRIPT" "$PROJECT"; then
        echo "  ✗ ERROR: patch_reseed.py failed for $PROJECT_NAME — skipping build"
        FAIL=$((FAIL + 1))
        FAILED_PROJECTS+=("$PROJECT_NAME (patch failed)")
        echo ""
        continue
    fi

    # ── 2. Build ──────────────────────────────────────────────────────────────
    echo "  [2/3] Building..."
    echo ""

    mkdir -p logs
    LOG_FILE="logs/build-$(date +%Y%m%d-%H%M%S).log"

    ./gradlew clean bundlePlaystoreRelease \
        -PKEY_ALIAS="$KEY_ALIAS" \
        -PKEY_PASSWORD="$KEY_PASSWORD" \
        -PKEYSTORE="$KEYSTORE" \
        -PSTORE_PASSWORD="$STORE_PASSWORD" \
        -PBUILD_ENV=MAINNET \
        2>&1 | tee "$LOG_FILE"

    BUILD_EXIT=${PIPESTATUS[0]}

    ./gradlew --stop > /dev/null 2>&1

    if [ "$BUILD_EXIT" -ne 0 ]; then
        echo ""
        echo "  ✗ FAILED:  $PROJECT_NAME build failed (exit code: $BUILD_EXIT)"
        echo "  Log: $PROJECT/$LOG_FILE"
        FAIL=$((FAIL + 1))
        FAILED_PROJECTS+=("$PROJECT_NAME")
        echo ""
        continue
    fi

    echo ""
    echo "  ✔ Build succeeded: $PROJECT_NAME"
    echo "  Log: $PROJECT/$LOG_FILE"

    # ── 3. Bump version, commit, push ─────────────────────────────────────────
    echo "  [3/3] Bumping version and committing..."

    # Capture key=value output from bump_version.py
    BUMP_OUTPUT="$(python3 "$BUMP_SCRIPT" "$PROJECT" 2>&1)"
    BUMP_EXIT=$?

    if [ $BUMP_EXIT -ne 0 ]; then
        echo "  ✗ WARNING: bump_version.py failed — build counted as success but no commit made"
        echo "  $BUMP_OUTPUT"
        PASS=$((PASS + 1))
        echo ""
        continue
    fi

    # Parse the key=value lines into shell variables
    eval "$(echo "$BUMP_OUTPUT" | grep -E '^(OLD|NEW)_(CODE|NAME)=')"

    # Determine the current branch
    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "HEAD" ]; then
        echo "  ✗ WARNING: could not determine current git branch — skipping commit"
        PASS=$((PASS + 1))
        echo ""
        continue
    fi

    # Stage changed files: the patched router file + the bumped build.gradle
    git add -A

    COMMIT_MSG="Fix EmbeddedI2PRouter reseed fetch: multi-mirror + disk cache ($BUILD_DATE)

- Replace single RESEED_LIST_URL with RESEED_LIST_MIRRORS (3 mirrors, shuffled)
- Add 7-day on-disk cache so warm boots skip the network entirely
- Stale-cache fallback if all mirrors fail at startup
- versionCode: $OLD_CODE → $NEW_CODE
- versionName: $OLD_NAME → $NEW_NAME"

    if ! git commit -m "$COMMIT_MSG"; then
        echo "  ✗ WARNING: git commit failed (nothing to commit?) — skipping push"
        PASS=$((PASS + 1))
        echo ""
        continue
    fi

    if ! git push origin "$CURRENT_BRANCH"; then
        echo "  ✗ WARNING: git push failed — commit is local only"
        echo "             Run: git push origin $CURRENT_BRANCH"
    else
        echo "  ✔ Pushed to origin/$CURRENT_BRANCH"
    fi

    echo "  ✔ Version bumped: $OLD_NAME (code $OLD_CODE) → $NEW_NAME (code $NEW_CODE)"
    PASS=$((PASS + 1))
    echo ""
done

echo "=============================================="
echo "  Build Summary"
echo "=============================================="
echo "  Total:   $TOTAL"
echo "  Passed:  $PASS ✔"
echo "  Failed:  $FAIL ✗"

if [ ${#FAILED_PROJECTS[@]} -gt 0 ]; then
    echo ""
    echo "  Failed projects:"
    for F in "${FAILED_PROJECTS[@]}"; do
        echo "    - $F"
    done
fi

echo "=============================================="

[ $FAIL -eq 0 ] && exit 0 || exit 1
