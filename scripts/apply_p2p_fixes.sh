#!/usr/bin/env bash
#
# apply_p2p_fixes.sh — drop the fixed files from p2p-suite-fixes.zip into your
# local git checkouts under ~/git, bump each changed app's version, then
# commit (and optionally push) each repo that changed.
#
# Usage:
#   ./apply_p2p_fixes.sh                              # apply + bump + commit, ask before each push
#   ./apply_p2p_fixes.sh --yes                         # apply + bump + commit + push, no prompts
#   ./apply_p2p_fixes.sh --no-push                     # apply + bump + commit only, never push
#   ./apply_p2p_fixes.sh --no-commit                   # apply only (old behavior, no version bump either)
#   ./apply_p2p_fixes.sh --no-version-bump             # apply + commit, but leave versionCode/versionName alone
#   ./apply_p2p_fixes.sh /path/to/git /path/to/p2p-suite-fixes --yes
#
# Flags can go anywhere on the command line; the first two non-flag args are
# taken as GIT_DIR and FIXES_DIR respectively.
#
# What it does, per repo:
#   1. Copies in the fixed files (backing up any existing file to
#      <file>.orig.bak the first time, so re-running is safe).
#   2. Bumps that app's versionCode (+1) and versionName (patch segment +1,
#      preserving any suffix like "-p2p") in app/build.gradle(.kts) — part of
#      the same commit as the fix. Skipped with --no-version-bump or if the
#      version fields can't be parsed (a warning is printed either way).
#   3. `git add` on exactly those files (the fixed file(s) + the build file).
#   4. `git commit` with a message describing the fix(es) applied to that repo.
#   5. `git push` on the current branch's upstream — asked for confirmation
#      per repo unless --yes was given, and skipped entirely with --no-push.
#
# Nothing is force-pushed and no branch is created or switched — it commits
# to whatever branch is currently checked out in each repo.
#
# Project naming: as of this delivery, directory names under fixes/files/
# (and the git checkout names under ~/git this script expects) no longer
# carry the old "-code" suffix (e.g. "ajo-android-p2p", not
# "ajo-android-p2p-code") — matching what create-p2p-code-archives.sh now
# produces and what's on disk under ~/git. If your local checkouts still use
# the old "-code" names, either rename them or add back a mapping below.

set -euo pipefail

GIT_DIR=""
FIXES_DIR=""
ASSUME_YES=0
DO_COMMIT=1
DO_PUSH=1
DO_VERSION_BUMP=1

for arg in "$@"; do
    case "$arg" in
        --yes|-y)            ASSUME_YES=1 ;;
        --no-push)           DO_PUSH=0 ;;
        --no-commit)         DO_COMMIT=0; DO_PUSH=0; DO_VERSION_BUMP=0 ;;
        --no-version-bump)   DO_VERSION_BUMP=0 ;;
        *)
            if [ -z "$GIT_DIR" ]; then GIT_DIR="$arg"
            elif [ -z "$FIXES_DIR" ]; then FIXES_DIR="$arg"
            fi
            ;;
    esac
done

GIT_DIR="${GIT_DIR:-$HOME/git}"
FIXES_DIR="${FIXES_DIR:-$HOME/Downloads/p2p-suite-fixes}"

# The zip's own top-level folder is "fixes/", so depending on how it was
# extracted, "files/" ends up either directly under FIXES_DIR or one level
# deeper at FIXES_DIR/fixes/files. Try both rather than guessing wrong.
FILES_DIR=""
for candidate in "$FIXES_DIR/files" "$FIXES_DIR/fixes/files"; do
    if [ -d "$candidate" ]; then
        FILES_DIR="$candidate"
        break
    fi
done

if [ -z "$FILES_DIR" ]; then
    echo "error: could not find a 'files' directory under $FIXES_DIR" >&2
    echo "  looked in: $FIXES_DIR/files and $FIXES_DIR/fixes/files" >&2
    echo "  pass the correct extracted path as the 2nd argument, e.g.:" >&2
    echo "    ./apply_p2p_fixes.sh ~/git ~/Downloads/p2p-suite-fixes/fixes --yes" >&2
    exit 1
fi
if [ ! -d "$GIT_DIR" ]; then
    echo "error: git directory not found at $GIT_DIR" >&2
    exit 1
fi

# Project names now match 1:1 between fixes/files/<name> and the git checkout
# ~/git/<name> — both dropped the old "-code" suffix. If a project in your
# git dir still uses the old suffixed name, add an override here, e.g.:
#   [ajo-android-p2p]="ajo-android-p2p-code"
declare -A REPO_MAP=(
    [ajo-android-p2p]="ajo-android-p2p"
    [scrowit-android-p2p]="scrowit-android-p2p"
    [verzus-p2p]="verzus-p2p"
    [sixdegrees-p2p]="sixdegrees-p2p"
    [buzzr-p2p]="buzzr-p2p"
    [kabu-kabu-p2p]="kabu-kabu-p2p"
)

# Short, specific commit message per repo (matches AUDIT_REPORT.md, pass 3).
# Only projects with fixes in *this* delivery need an entry — a project dir
# with no matching key here still gets its files applied, just with a
# generic commit message (see COMMIT_MSG lookup below).
declare -A COMMIT_MSG=(
    [verzus-p2p]="Fix wrong payout formula in calculatePotentialEarnings()

- BettingServiceUtils.kt: calculatePotentialEarnings() computed the
  acceptor's potential earnings as bet.amount / bet.odds, diverging from
  the actual payout formula used everywhere settlement really happens —
  BettingService.calculatePayoutAmount(), BettingWalletOperations.
  calculatePayoutAmount(), and BettingServiceNetworkOps.calculatePayout()
  all agree on bet.amount * (2.0 - bet.odds) for the acceptor. Fixed to
  match. No confirmed live caller today, but it's a public method on a
  wired class — hardening fix so a future 'potential winnings' UI doesn't
  inherit a wrong number."

    [ajo-android-p2p]="Fix precision loss in ServiceFeeManager.calculateFee()'s minFee

- ServiceFeeManager.kt: calculateFee()'s minFee still computed customMinFee
  (or the MIN_FEE_AMOUNT_ATOMIC constant) via toDouble() / 1e12 — the same
  lossy round-trip already fixed in calculateFeeAtomic() last pass, and
  explicitly flagged then as left out of scope. customMinFee is a
  caller-supplied Long, not guaranteed to round-trip cleanly through
  Double, so closed it out: BigDecimal(customMinFee ?: MIN_FEE_AMOUNT_ATOMIC)
  .divide(ATOMIC_SCALE, 12, DOWN), matching the pattern used for the gross
  amount two lines below. Hardening fix — doesn't change today's output."

    [scrowit-android-p2p]="Fix precision loss in ServiceFeeManager.calculateFee()'s minFee

- ServiceFeeManager.kt: same fix as ajo's copy of this file (see that
  repo's commit for the full explanation)."
)

DEFAULT_COMMIT_MSG="Apply fixes from p2p-suite-fixes (see AUDIT_REPORT.md for details)"

# ---------------------------------------------------------------------------
# Version bump helper
# ---------------------------------------------------------------------------
# Bumps versionCode (+1) and the last dot-segment of versionName (+1),
# preserving any trailing non-numeric suffix (e.g. "-p2p"). Operates on the
# *first* match of each in the file (the defaultConfig block), so later
# per-flavor overrides (e.g. versionNameSuffix) are untouched.
find_build_gradle() {
    local repo_dir="$1"
    for f in "$repo_dir/app/build.gradle.kts" "$repo_dir/app/build.gradle"; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

bump_version() {
    local gradle_file="$1"
    local old_code old_name new_code new_name numeric suffix

    old_code="$(grep -oE 'versionCode[[:space:]]*=[[:space:]]*[0-9]+' "$gradle_file" | head -1 | grep -oE '[0-9]+$')"
    old_name="$(grep -oE 'versionName[[:space:]]*=[[:space:]]*"[^"]+"' "$gradle_file" | head -1 | sed -E 's/.*"([^"]+)"/\1/')"

    if [ -z "$old_code" ] || [ -z "$old_name" ]; then
        echo "  ! could not find versionCode/versionName in $gradle_file — skipping version bump" >&2
        return 1
    fi

    new_code=$((old_code + 1))

    if [[ "$old_name" =~ ^([0-9]+(\.[0-9]+)*)(.*)$ ]]; then
        numeric="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[3]}"
        IFS='.' read -ra parts <<< "$numeric"
        last_idx=$((${#parts[@]} - 1))
        parts[$last_idx]=$((10#${parts[$last_idx]} + 1))
        new_numeric="$(IFS='.'; echo "${parts[*]}")"
        new_name="${new_numeric}${suffix}"
    else
        echo "  ! could not parse versionName '$old_name' in $gradle_file — skipping version bump" >&2
        return 1
    fi

    # Replace only the first occurrence of each (defaultConfig block).
    sed -i "0,/versionCode[[:space:]]*=[[:space:]]*${old_code}\b/s//versionCode = ${new_code}/" "$gradle_file"
    sed -i "0,/versionName[[:space:]]*=[[:space:]]*\"${old_name}\"/s//versionName = \"${new_name}\"/" "$gradle_file"

    echo "  version bumped: versionCode ${old_code} -> ${new_code}, versionName \"${old_name}\" -> \"${new_name}\""
    return 0
}

total_files=0
total_committed=0
total_pushed=0
total_missing_repos=0
total_version_bumped=0

for zip_name in "${!REPO_MAP[@]}"; do
    repo_name="${REPO_MAP[$zip_name]}"
    src_root="$FILES_DIR/$zip_name"
    dst_root="$GIT_DIR/$repo_name"

    [ -d "$src_root" ] || continue

    echo ""
    echo "=== $repo_name ==="

    if [ ! -d "$dst_root" ]; then
        echo "  ! skipping — repo not found at $dst_root"
        total_missing_repos=$((total_missing_repos + 1))
        continue
    fi

    is_git_repo=0
    [ -d "$dst_root/.git" ] && is_git_repo=1
    if [ "$is_git_repo" -eq 0 ]; then
        echo "  ! $dst_root is not a git repo — copying files but skipping commit/push"
    fi

    rel_paths=()
    while IFS= read -r -d '' src_file; do
        rel_path="${src_file#"$src_root"/}"
        dst_file="$dst_root/$rel_path"

        mkdir -p "$(dirname "$dst_file")"

        if [ -f "$dst_file" ] && [ ! -f "$dst_file.orig.bak" ]; then
            cp "$dst_file" "$dst_file.orig.bak"
            echo "  backed up: $rel_path -> $(basename "$dst_file").orig.bak"
        fi

        cp "$src_file" "$dst_file"
        echo "  applied:   $rel_path"
        total_files=$((total_files + 1))
        rel_paths+=("$rel_path")
    done < <(find "$src_root" -type f -print0)

    [ "$is_git_repo" -eq 1 ] || continue

    # Version bump — before diff/add so it's part of the same commit.
    if [ "$DO_COMMIT" -eq 1 ] && [ "$DO_VERSION_BUMP" -eq 1 ]; then
        if gradle_file="$(find_build_gradle "$dst_root")"; then
            if bump_version "$gradle_file"; then
                rel_gradle="${gradle_file#"$dst_root"/}"
                rel_paths+=("$rel_gradle")
                total_version_bumped=$((total_version_bumped + 1))
            fi
        else
            echo "  ! no app/build.gradle(.kts) found under $dst_root — skipping version bump"
        fi
    fi

    echo "  --- diff ---"
    git -C "$dst_root" --no-pager diff --stat -- "${rel_paths[@]}" 2>/dev/null || true

    if [ "$DO_COMMIT" -eq 0 ]; then
        continue
    fi

    if git -C "$dst_root" diff --quiet -- "${rel_paths[@]}" 2>/dev/null && \
       git -C "$dst_root" diff --cached --quiet -- "${rel_paths[@]}" 2>/dev/null; then
        echo "  no changes relative to git HEAD — nothing to commit"
        continue
    fi

    commit_msg="${COMMIT_MSG[$zip_name]:-$DEFAULT_COMMIT_MSG}"

    git -C "$dst_root" add -- "${rel_paths[@]}"
    if git -C "$dst_root" commit -m "$commit_msg" >/dev/null; then
        echo "  committed."
        total_committed=$((total_committed + 1))
    else
        echo "  ! commit failed or nothing staged — skipping push"
        continue
    fi

    if [ "$DO_PUSH" -eq 0 ]; then
        continue
    fi

    branch="$(git -C "$dst_root" rev-parse --abbrev-ref HEAD)"
    do_push="$ASSUME_YES"
    if [ "$ASSUME_YES" -ne 1 ]; then
        read -r -p "  push $repo_name to origin/$branch now? [y/N] " reply
        case "$reply" in
            [yY]|[yY][eE][sS]) do_push=1 ;;
            *) do_push=0 ;;
        esac
    fi

    if [ "$do_push" -eq 1 ]; then
        if git -C "$dst_root" push origin "$branch"; then
            echo "  pushed to origin/$branch."
            total_pushed=$((total_pushed + 1))
        else
            echo "  ! push failed — commit is in place locally, push manually when ready."
        fi
    else
        echo "  skipped push — commit is local only. Push manually with:"
        echo "    git -C $dst_root push origin $branch"
    fi
done

echo ""
echo "Done. $total_files file(s) applied, $total_version_bumped version(s) bumped, $total_committed repo(s) committed, $total_pushed repo(s) pushed."
if [ "$total_missing_repos" -gt 0 ]; then
    echo "$total_missing_repos repo(s) referenced in the fix set were not found under $GIT_DIR — check the path."
fi
echo ""
echo "Backups (if any originals existed) are alongside each file as <file>.orig.bak — safe to delete once you're happy."
