#!/bin/bash
# Rebuild all P2P projects (bundlePlaystoreRelease). Build only: no patching,
# no version bump, no git commit, no git push.
#
# Usage:
#   ./rebuild_all.sh                        # all six projects
#   ./rebuild_all.sh verzus-p2p buzzr-p2p   # only the named ones
#
# Signing secrets come from the environment (VERZUS_KEY_PASSWORD,
# VERZUS_STORE_PASSWORD); if unset you are prompted, nothing is stored in this file.

ALL_APPS=(ajo-android-p2p buzzr-p2p kabu-kabu-p2p scrowit-android-p2p sixdegrees-p2p verzus-p2p)
GIT_ROOT="${GIT_ROOT:-$HOME/git}"
LOG_DIR="$HOME/rebuild-logs"

KEY_ALIAS="${VERZUS_KEY_ALIAS:-key0}"
KEYSTORE="${VERZUS_KEYSTORE:-$GIT_ROOT/server_extras/techducat.jks}"
KEY_PASSWORD="${VERZUS_KEY_PASSWORD:-}"
STORE_PASSWORD="${VERZUS_STORE_PASSWORD:-}"

[ -f "$KEYSTORE" ] || { echo "ERROR: keystore not found: $KEYSTORE"; exit 1; }
[ -n "$STORE_PASSWORD" ] || { read -r -s -p "Keystore password: " STORE_PASSWORD; echo; }
[ -n "$KEY_PASSWORD" ]   || { read -r -s -p "Key password (Enter = same as keystore): " KEY_PASSWORD; echo; }
[ -n "$KEY_PASSWORD" ]   || KEY_PASSWORD="$STORE_PASSWORD"

if [ $# -gt 0 ]; then
    APPS=("$@")
    for a in "${APPS[@]}"; do
        case " ${ALL_APPS[*]} " in *" $a "*) ;; *) echo "ERROR: '$a' is not one of: ${ALL_APPS[*]}"; exit 2 ;; esac
    done
else
    APPS=("${ALL_APPS[@]}")
fi

mkdir -p "$LOG_DIR"
TOTAL=${#APPS[@]}; PASS=0; FAIL=0; FAILED=(); ARTIFACTS=()
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "=============================================="
echo "  Rebuilding $TOTAL project(s): bundlePlaystoreRelease"
echo "  Logs: $LOG_DIR"
echo "=============================================="

for APP in "${APPS[@]}"; do
    PROJECT="$GIT_ROOT/$APP"
    echo ""
    echo "---------- [$((PASS + FAIL + 1))/$TOTAL] $APP ----------"

    if [ ! -x "$PROJECT/gradlew" ]; then
        echo "  x gradlew not found/executable in $PROJECT"
        FAIL=$((FAIL + 1)); FAILED+=("$APP (no gradlew)"); continue
    fi

    LOG_FILE="$LOG_DIR/$APP-$STAMP.log"
    ( cd "$PROJECT" && ./gradlew clean bundlePlaystoreRelease \
        -PKEY_ALIAS="$KEY_ALIAS" \
        -PKEY_PASSWORD="$KEY_PASSWORD" \
        -PKEYSTORE="$KEYSTORE" \
        -PSTORE_PASSWORD="$STORE_PASSWORD" \
        -PBUILD_ENV=MAINNET ) 2>&1 | tee "$LOG_FILE"
    BUILD_EXIT=${PIPESTATUS[0]}
    ( cd "$PROJECT" && ./gradlew --stop >/dev/null 2>&1 )

    if [ "$BUILD_EXIT" -ne 0 ]; then
        echo "  x FAILED (exit $BUILD_EXIT). Log: $LOG_FILE"
        FAIL=$((FAIL + 1)); FAILED+=("$APP"); continue
    fi

    AAB="$(find "$PROJECT/app/build/outputs/bundle" -name '*.aab' -newer "$LOG_FILE" 2>/dev/null | head -1)"
    [ -z "$AAB" ] && AAB="$(find "$PROJECT/app/build/outputs/bundle" -name '*.aab' 2>/dev/null | head -1)"
    echo "  OK: $APP"
    ARTIFACTS+=("$APP: ${AAB:-<no .aab found under app/build/outputs/bundle>}")
    PASS=$((PASS + 1))
done

echo ""
echo "=============================================="
echo "  Build Summary: $PASS passed, $FAIL failed (of $TOTAL)"
echo "=============================================="
for a in "${ARTIFACTS[@]}"; do echo "  $a"; done
if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""; echo "  Failed:"; for f in "${FAILED[@]}"; do echo "    - $f"; done
fi

[ "$FAIL" -eq 0 ]
