#!/usr/bin/env bash
#
# apply_p2p_patches.sh -- apply the UPnP-crash + Firebase-removal patches to the
# six P2P app checkouts, bump each app's version ONCE, and commit.
#
# Only these six repos are ever touched (anything else under ~/git, e.g.
# kotlin-networking-p2p, is ignored):
#   ajo-android-p2p buzzr-p2p kabu-kabu-p2p scrowit-android-p2p sixdegrees-p2p verzus-p2p
#
# Usage:
#   ./apply_p2p_patches.sh --check          # report only; changes nothing. RUN THIS FIRST.
#   ./apply_p2p_patches.sh                  # apply + bump version + commit (no push)
#   ./apply_p2p_patches.sh --push           # ...and push each repo (asks first)
#   ./apply_p2p_patches.sh --push --yes     # ...push without asking
#   ./apply_p2p_patches.sh --no-version-bump
#   ./apply_p2p_patches.sh --patches DIR    # where the *.patch files are (default: this script's folder)
#   ./apply_p2p_patches.sh --git DIR        # where the checkouts are (default: ~/git)
#   ./apply_p2p_patches.sh verzus-p2p kabu-kabu-p2p   # limit to named apps
#
# Safe to re-run:
#   * a patch that is already applied is detected and skipped (no second commit,
#     no second version bump);
#   * a patch that does not apply cleanly (the checkout has diverged) is skipped
#     with the reason shown -- nothing is half-applied;
#   * if any file the patch touches has uncommitted changes, that repo is skipped;
#   * commits use an explicit path list, so unrelated staged work is NOT swept in;
#   * nothing is force-pushed, no branch is created or switched.
#
# Portable: works with bash 3.2+ (macOS) and GNU/BSD userland. Needs git and perl.

set -u

APPS=(ajo-android-p2p buzzr-p2p kabu-kabu-p2p scrowit-android-p2p sixdegrees-p2p verzus-p2p)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PATCH_DIR="$SCRIPT_DIR"
GIT_DIR="$HOME/git"
CHECK_ONLY=0; DO_BUMP=1; DO_PUSH=0; ASSUME_YES=0
SELECTED=()

while [ $# -gt 0 ]; do
    case "$1" in
        --check)            CHECK_ONLY=1 ;;
        --no-version-bump)  DO_BUMP=0 ;;
        --push)             DO_PUSH=1 ;;
        --yes|-y)           ASSUME_YES=1 ;;
        --patches)          shift; PATCH_DIR="${1:?--patches needs a directory}" ;;
        --git)              shift; GIT_DIR="${1:?--git needs a directory}" ;;
        -h|--help)          sed -n '2,32p' "$0"; exit 0 ;;
        -*)                 echo "unknown option: $1" >&2; exit 2 ;;
        *)                  SELECTED+=("$1") ;;
    esac
    shift
done

is_known_app() { local a; for a in "${APPS[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
if [ ${#SELECTED[@]} -gt 0 ]; then
    for a in "${SELECTED[@]}"; do
        is_known_app "$a" || { echo "error: '$a' is not one of: ${APPS[*]}" >&2; exit 2; }
    done
    TARGETS=("${SELECTED[@]}")
else
    TARGETS=("${APPS[@]}")
fi

command -v git  >/dev/null || { echo "error: git not found"  >&2; exit 1; }
[ "$DO_BUMP" -eq 1 ] && ! command -v perl >/dev/null && {
    echo "warning: perl not found -- version bump disabled" >&2; DO_BUMP=0; }
[ -d "$PATCH_DIR" ] || { echo "error: patch directory not found: $PATCH_DIR" >&2; exit 1; }
[ -d "$GIT_DIR" ]   || { echo "error: git directory not found: $GIT_DIR"     >&2; exit 1; }

# ---------------------------------------------------------------------------
commit_message() {
    local common
    common="UPnP: disable the embedded I2P router's UPnP (i2np.upnp.enable=false in
router.config AND as a System property on every start, since router.config is
only written on first boot) and keep org.cybergarage.** in R8. Fixes the fatal
'RuntimeException: No XML parser defined' thrown on the SSDP thread when any
LAN device answers and R8 has stripped the reflectively-loaded XML parser."
    case "$1" in
    ajo-android-p2p)
        printf '%s\n\n%s\n\n%s\n' "Fix UPnP crash; remove remaining Firebase/Google-auth traces" "$common" \
"Firebase: drop Firebase/Firestore/GMS ProGuard keep rules, the
default_web_client_id OAuth client ID and unused sign-in strings; rewrite stale
Firestore-mailbox docs/comments; Profile no longer claims Google Sign-In." ;;
    scrowit-android-p2p)
        printf '%s\n\n%s\n\n%s\n' "Fix UPnP crash; remove remaining Firebase/Google-auth traces" "$common" \
"Firebase: drop Firebase/Firestore/GMS keep rules, default_web_client_id,
firestore.rules and the Firestore schema/mailbox docs; 'Firebase UID' ->
anonymous user ID; view id btnGoogleSignIn -> btnSignIn (code + 2 layouts).
fix-i2p-proguard.sh now injects the cybergarage rule too." ;;
    verzus-p2p)
        printf '%s\n\n%s\n\n%s\n' "Fix UPnP crash; remove leftover Firebase plugin declarations" "$common" \
"Firebase: remove the google-services/crashlytics plugin declarations from the
root build.gradle.kts; clean manifest, strings, README and comments." ;;
    kabu-kabu-p2p)
        printf '%s\n\n%s\n\n%s\n' "Fix UPnP crash; remove Firebase (Crashlytics/Analytics) entirely" "$common" \
"Firebase: remove google-services + crashlytics plugins, firebase-bom,
crashlytics/analytics dependencies, app/google-services.json and all Firebase
code in KabuKabuApp. Release logging is now a W+ Timber tree to logcat only
(same as Verzus); nothing leaves the device." ;;
    buzzr-p2p|sixdegrees-p2p)
        printf '%s\n\n%s\n\n%s\n' "Fix UPnP crash; clean Firebase-era leftovers" "$common" \
"Docs/comments/strings that referred to the removed cloud SDKs were reworded." ;;
    esac
}

# Extra tracked files that are Firebase artifacts but were not in the uploaded
# source snapshot (so the patch cannot delete them). Removed in the same commit.
extra_removals() {
    case "$1" in
        scrowit-android-p2p) echo "firestore.rules" ;;
    esac
}

# Bump versionCode (+1) and the last numeric segment of versionName (+1) in the
# FIRST non-comment occurrence, keeping suffixes such as "-p2p".
bump_version() {
    local f="$1" oc on nc nn
    oc="$(grep -E '^[[:space:]]*versionCode[[:space:]]*=' "$f" | head -1 | grep -oE '[0-9]+' | head -1)"
    on="$(grep -E '^[[:space:]]*versionName[[:space:]]*=' "$f" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
    if [ -z "$oc" ] || [ -z "$on" ]; then
        echo "    ! versionCode/versionName not found in ${f##*/} -- version NOT bumped"; return 1
    fi
    perl -i -pe '
        BEGIN { $c = $n = 0 }
        next if /^\s*\/\//;
        if (!$c && s/(versionCode\s*=\s*)(\d+)/$1.($2+1)/e) { $c = 1 }
        if (!$n && s/(versionName\s*=\s*")(\d+(?:\.\d+)*)/my ($p,$v)=($1,$2); $v =~ s{(\d+)$}{$1+1}e; $p.$v/e) { $n = 1 }
    ' "$f" || return 1
    nc="$(grep -E '^[[:space:]]*versionCode[[:space:]]*=' "$f" | head -1 | grep -oE '[0-9]+' | head -1)"
    nn="$(grep -E '^[[:space:]]*versionName[[:space:]]*=' "$f" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
    echo "    version: versionCode $oc -> $nc, versionName \"$on\" -> \"$nn\""
}

find_build_gradle() {
    local f
    for f in "$1/app/build.gradle.kts" "$1/app/build.gradle"; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

verify_no_firebase() {
    local repo="$1" hits files
    hits="$(git -C "$repo" grep -nIiE 'firebase|firestore|crashlytics|google-services|gms\.google|default_web_client_id|google.?sign.?in' 2>/dev/null)"
    files="$(git -C "$repo" ls-files | grep -iE 'firebase|firestore|google-services' || true)"
    if [ -z "$hits" ] && [ -z "$files" ]; then
        echo "    verify: clean (no Firebase references in tracked files)"
    else
        echo "    verify: LEFTOVERS FOUND in tracked files (not covered by the patch):"
        [ -n "$files" ] && echo "$files" | sed 's/^/      file: /'
        [ -n "$hits" ]  && echo "$hits"  | head -15 | cut -c1-160 | sed 's/^/      /'
        local n; n="$(echo "$hits" | grep -c . || true)"
        [ "${n:-0}" -gt 15 ] && echo "      ... and $((n-15)) more lines"
        return 1
    fi
}

# ---------------------------------------------------------------------------
n_applied=0; n_already=0; n_conflict=0; n_skipped=0; n_pending=0; n_pushed=0; n_leftover=0

for app in "${TARGETS[@]}"; do
    patch="$PATCH_DIR/$app.patch"
    repo="$GIT_DIR/$app"
    echo ""
    echo "=== $app ==="

    if [ ! -f "$patch" ]; then echo "  ! patch not found: $patch -- skipped"; n_skipped=$((n_skipped+1)); continue; fi
    if [ ! -d "$repo" ]; then echo "  ! checkout not found: $repo -- skipped"; n_skipped=$((n_skipped+1)); continue; fi

    # Must be the repo's own top level (never operate on a parent repo by accident).
    top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)"
    real="$(cd "$repo" && pwd -P)"
    if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$real" ]; then
        echo "  ! $repo is not the root of a git repository -- skipped"; n_skipped=$((n_skipped+1)); continue
    fi

    branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    echo "  branch: $branch"

    # Is it pending, already applied, or conflicting?
    if git -C "$repo" apply --check --whitespace=nowarn "$patch" 2>/dev/null; then
        state=pending
    elif git -C "$repo" apply --check -R --whitespace=nowarn "$patch" 2>/dev/null; then
        state=applied
    else
        state=conflict
    fi

    case "$state" in
    applied)
        echo "  already applied -- nothing to do (no commit, no version bump)"
        n_already=$((n_already+1))
        [ "$CHECK_ONLY" -eq 0 ] && { verify_no_firebase "$repo" || n_leftover=$((n_leftover+1)); }
        continue ;;
    conflict)
        echo "  ! CONFLICT: this checkout has diverged from the code the patch was made against."
        git -C "$repo" apply --check --whitespace=nowarn "$patch" 2>&1 | head -6 | sed 's/^/      /'
        echo "    Nothing was changed. To resolve by hand:  git -C $repo apply --3way $patch"
        n_conflict=$((n_conflict+1)); continue ;;
    esac

    # pending: files the patch touches
    paths=()
    while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(git -C "$repo" apply --numstat "$patch" | awk -F'\t' '{print $3}')
    echo "  pending: patch changes ${#paths[@]} file(s)"

    dirty="$(git -C "$repo" status --porcelain -- "${paths[@]}" 2>/dev/null)"
    if [ -n "$dirty" ]; then
        echo "  ! files the patch touches have uncommitted changes -- skipped. Commit or stash them first:"
        echo "$dirty" | sed 's/^/      /'
        n_skipped=$((n_skipped+1)); continue
    fi

    if [ "$CHECK_ONLY" -eq 1 ]; then
        echo "  [check] would apply cleanly"
        for x in $(extra_removals "$app"); do
            git -C "$repo" ls-files --error-unmatch -- "$x" >/dev/null 2>&1 && echo "  [check] would also git rm $x"
        done
        n_pending=$((n_pending+1)); continue
    fi

    if ! git -C "$repo" apply --index --whitespace=nowarn "$patch" 2>/tmp/apply_err.$$; then
        echo "  ! git apply failed -- skipped:"; sed 's/^/      /' /tmp/apply_err.$$; rm -f /tmp/apply_err.$$
        n_conflict=$((n_conflict+1)); continue
    fi
    rm -f /tmp/apply_err.$$
    echo "  applied patch (staged)"

    for x in $(extra_removals "$app"); do
        if git -C "$repo" ls-files --error-unmatch -- "$x" >/dev/null 2>&1; then
            git -C "$repo" rm -q -- "$x" && { echo "  removed tracked Firebase artifact: $x"; paths+=("$x"); }
        elif [ -e "$repo/$x" ]; then
            echo "  note: $x exists but is untracked -- delete it yourself if unwanted"
        fi
    done

    if [ "$DO_BUMP" -eq 1 ]; then
        if gf="$(find_build_gradle "$repo")"; then
            if bump_version "$gf"; then
                rel="${gf#"$repo"/}"
                git -C "$repo" add -- "$rel"
                case " ${paths[*]} " in *" $rel "*) ;; *) paths+=("$rel") ;; esac
            fi
        else
            echo "    ! no app/build.gradle(.kts) -- version NOT bumped"
        fi
    fi

    if git -C "$repo" commit -q -m "$(commit_message "$app")" -- "${paths[@]}"; then
        echo "  committed: $(git -C "$repo" log -1 --format='%h %s')"
        n_applied=$((n_applied+1))
    else
        echo "  ! commit failed -- changes are staged in $repo; resolve manually"
        n_skipped=$((n_skipped+1)); continue
    fi

    verify_no_firebase "$repo" || n_leftover=$((n_leftover+1))

    if [ "$DO_PUSH" -eq 1 ]; then
        go="$ASSUME_YES"
        if [ "$ASSUME_YES" -ne 1 ]; then
            read -r -p "  push $app ($branch) now? [y/N] " r
            case "$r" in [yY]|[yY][eE][sS]) go=1 ;; *) go=0 ;; esac
        fi
        if [ "$go" -eq 1 ]; then
            if git -C "$repo" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
                git -C "$repo" push && { echo "  pushed."; n_pushed=$((n_pushed+1)); } || echo "  ! push failed -- commit is local; push manually"
            else
                echo "  ! '$branch' has no upstream -- not pushed. Run: git -C $repo push -u origin $branch"
            fi
        else
            echo "  not pushed. Later:  git -C $repo push"
        fi
    fi
done

echo ""
if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "CHECK: $n_pending would apply cleanly, $n_already already applied, $n_conflict conflict(s), $n_skipped skipped."
else
    echo "DONE: $n_applied committed, $n_already already applied, $n_conflict conflict(s), $n_skipped skipped, $n_pushed pushed."
    [ "$n_leftover" -gt 0 ] && echo "NOTE: $n_leftover repo(s) still contain Firebase references in files the patches don't cover (listed above)."
fi
[ "$n_conflict" -gt 0 ] && exit 1
exit 0
