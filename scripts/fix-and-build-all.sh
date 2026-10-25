#!/usr/bin/env bash
# fix-and-build-all.sh
# For every Android project in ~/git/*-p2p (except kotlin-networking-p2p):
#   1. Detects whether the project uses Monero or I2P
#   2. Audits proguard-rules.pro and patches + commits if rules are missing
#   3. Builds bundlePlaystoreRelease (skipping verzus-p2p which is already done)
#
# Signing env vars (VERZUS_KEY_ALIAS, VERZUS_KEY_PASSWORD, VERZUS_KEYSTORE,
# VERZUS_STORE_PASSWORD) must be set in the environment (they are in ~/.bashrc).
# Build logs are saved to <project>/logs/build-YYYYMMDD-HHMMSS.log
#
# Safe to re-run: skips projects whose proguard rules are already present.
#
# Usage:
#   ./fix-and-build-all.sh              # dry-run: shows what would change
#   ./fix-and-build-all.sh --apply      # patches, commits, and builds

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

PROJECTS=(
    "$HOME/git/verzus-p2p"
    "$HOME/git/ajo-android-p2p"
    "$HOME/git/scrowit-android-p2p"
    "$HOME/git/buzzr-p2p"
    "$HOME/git/sixdegrees-p2p"
)

# Already rebuilt and confirmed working — proguard fix still audited,
# but the build step is skipped.
SKIP_BUILD=(
    "$HOME/git/verzus-p2p"
)

DRY_RUN=true
[[ "${1:-}" == "--apply" ]] && DRY_RUN=false

# ── Monero keep rules ─────────────────────────────────────────────────────────

MONERO_SENTINEL="# --- Monero / xmrwallet JNI keep rules"

read -r -d '' MONERO_RULES << 'EOF' || true

# --- Monero / xmrwallet JNI keep rules (injected by fix-and-build-all.sh) ----
# libmonerujo.so resolves Java classes by fully-qualified name via JNI.
# R8 MUST NOT rename or strip any class in com.m2049r.xmrwallet.**.
# Without these rules the SO cannot find its callbacks and the process aborts:
#
#   java.lang.ClassNotFoundException: com.m2049r.xmrwallet.model.TransactionInfo
#   Fatal signal 6 (SIGABRT) — No pending exception expected

-keep class com.m2049r.xmrwallet.model.** { *; }
-keep class com.m2049r.xmrwallet.data.** { *; }
-keep class com.m2049r.xmrwallet.util.** { *; }
-keep class com.m2049r.xmrwallet.service.** { *; }
-keep class com.m2049r.xmrwallet.ledger.** { *; }
-dontwarn com.m2049r.xmrwallet.**

# Lombok generates getters/constructors on xmrwallet model classes at compile
# time (e.g. @Getter, @RequiredArgsConstructor on TransactionInfo).
-keep @lombok.Getter class * { *; }
-keep @lombok.RequiredArgsConstructor class * { *; }
-dontwarn lombok.**
# -----------------------------------------------------------------------------
EOF

MONERO_COMMIT="fix: add Monero JNI R8 keep rules to prevent ClassNotFoundException + SIGABRT

libmonerujo.so resolves Java classes by fully-qualified name at runtime
via JNI. With isMinifyEnabled = true, R8 was stripping/renaming the
com.m2049r.xmrwallet.** classes (TransactionInfo, Wallet, etc.) causing:

  java.lang.ClassNotFoundException: com.m2049r.xmrwallet.model.TransactionInfo
  Fatal signal 6 (SIGABRT) — No pending exception expected

Added keep rules for all xmrwallet sub-packages and Lombok annotations.

Injected by fix-and-build-all.sh"

# ── I2P keep rules ────────────────────────────────────────────────────────────

I2P_SENTINEL="# --- I2P Router keep rules"

read -r -d '' I2P_RULES << 'EOF' || true

# --- I2P Router keep rules (injected by fix-and-build-all.sh) ----------------
# All net.i2p classes are accessed via reflection in EmbeddedI2PRouter.
# Without these rules R8 renames/strips constructors and causes
# NoSuchMethodException at runtime (symptom: net.i2p.router.a.<init> []).

-keep class net.i2p.** { *; }
-dontwarn net.i2p.**

-keepclassmembers class net.i2p.router.Router {
    public <init>(java.lang.String, java.util.Properties);
    public <init>(java.lang.String);
    public <init>();
    public void runRouter();
    public boolean isAlive();
    public boolean isRunning();
    public void setKillVMOnEnd(boolean);
    public void shutdown(int);
}

-keepclassmembers class net.i2p.sam.SAMBridge {
    public <init>(java.lang.String, int, boolean, java.util.Properties, java.lang.String, java.io.File, net.i2p.sam.SAMSecureSessionInterface);
    public <init>(java.lang.String, int, java.util.Properties);
    public <init>();
    public void startListening();
}

-keep class net.i2p.router.RouterContext { *; }
-keep interface net.i2p.sam.SAMSecureSessionInterface { *; }
# -----------------------------------------------------------------------------
EOF

I2P_COMMIT="fix: add I2P R8 keep rules to prevent NoSuchMethodException

All net.i2p classes are accessed via reflection in EmbeddedI2PRouter.
Without these rules R8 renames/strips constructors and causes
NoSuchMethodException at runtime (symptom: net.i2p.router.a.<init> []).

Injected by fix-and-build-all.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

uses_monero() {
    local project="$1"
    [[ -f "$project/app/build.gradle.kts" ]] && \
        grep -qE "libmonerujo\.so|xmrwallet|m2049r" "$project/app/build.gradle.kts" && return 0
    [[ -d "$project/app/src/main/java/com/m2049r/xmrwallet" ]] && return 0
    return 1
}

uses_i2p() {
    local gradle="$1/app/build.gradle.kts"
    [[ -f "$gradle" ]] && grep -qE "i2p-android-client|router\.jar|net\.i2p" "$gradle"
}

skip_build() {
    local project="$1"
    for skip in "${SKIP_BUILD[@]}"; do
        [[ "$project" == "$skip" ]] && return 0
    done
    return 1
}

# Ensure proguard rules are present; patch + commit if not.
# Returns 0 if rules are present (either already were or just patched).
ensure_rules() {
    local project="$1"
    local proguard="$2"
    local sentinel="$3"
    local rules="$4"
    local commit_msg="$5"
    local label="$6"

    if [[ ! -f "$proguard" ]]; then
        warn "proguard-rules.pro missing in $(basename "$project")"
        if $DRY_RUN; then
            warn "  [DRY-RUN] Would create: $proguard"
            return 0
        fi
        echo "$rules" > "$proguard"
        info "  Created: $proguard"
    fi

    if grep -qF "$sentinel" "$proguard"; then
        info "  $label rules already present."
        return 0
    fi

    warn "  Missing $label rules — patching..."
    if $DRY_RUN; then
        warn "  [DRY-RUN] Would append $label rules to: $proguard"
        return 0
    fi

    printf '\n%s\n' "$rules" >> "$proguard"
    if ! grep -qF "$sentinel" "$proguard"; then
        error "  Patch failed (sentinel not found after write): $proguard"
        return 1
    fi
    info "  Patched: $proguard"

    (
        cd "$project"
        git add app/proguard-rules.pro
        git commit -m "$commit_msg"
    ) && info "  Committed: $(basename "$project")" \
      || { error "  Commit failed: $(basename "$project")"; return 1; }
}

do_build() {
    local project="$1"
    local logfile="$project/logs/build-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p "$project/logs"

    if $DRY_RUN; then
        info "  [DRY-RUN] Would run: ./gradlew clean bundlePlaystoreRelease → logs/build-<timestamp>.log"
        return 0
    fi

    info "  Building → bundlePlaystoreRelease"
    info "  Log: $logfile"

    (
        cd "$project"
        ./gradlew clean bundlePlaystoreRelease \
            -PKEY_ALIAS="${VERZUS_KEY_ALIAS}" \
            -PKEY_PASSWORD="${VERZUS_KEY_PASSWORD}" \
            -PKEYSTORE="${VERZUS_KEYSTORE}" \
            -PSTORE_PASSWORD="${VERZUS_STORE_PASSWORD}" \
            -PBUILD_ENV=MAINNET \
            2>&1 | tee "$logfile"
        ./gradlew --stop
    ) && info "  Build succeeded: $(basename "$project")" \
      || { error "  Build failed: $(basename "$project") — see $logfile"; return 1; }
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
echo "======================================================"
echo "  P2P Projects — ProGuard Fix + Build"
if $DRY_RUN; then
    echo "  Mode: DRY-RUN (pass --apply to patch + commit + build)"
else
    echo "  Mode: APPLY"
fi
echo "======================================================"
echo ""

built=()
failed=()
skipped_build=()
skipped_unknown=()

for project in "${PROJECTS[@]}"; do

    name="$(basename "$project")"
    echo "------------------------------------------------------"
    echo "  $name"
    echo "------------------------------------------------------"

    # ── Project must exist ────────────────────────────────────────────────────
    if [[ ! -d "$project" ]]; then
        error "  Directory not found: $project"
        failed+=("$name")
        continue
    fi

    # ── Detect library type and ensure rules ──────────────────────────────────
    if uses_monero "$project"; then
        info "  Library: Monero (xmrwallet)"
        ensure_rules "$project" \
            "$project/app/proguard-rules.pro" \
            "$MONERO_SENTINEL" \
            "$MONERO_RULES" \
            "$MONERO_COMMIT" \
            "Monero" || { failed+=("$name"); continue; }

    elif uses_i2p "$project"; then
        info "  Library: I2P"
        ensure_rules "$project" \
            "$project/app/proguard-rules.pro" \
            "$I2P_SENTINEL" \
            "$I2P_RULES" \
            "$I2P_COMMIT" \
            "I2P" || { failed+=("$name"); continue; }

    else
        warn "  No Monero or I2P dependency detected — skipping"
        skipped_unknown+=("$name")
        continue
    fi

    # ── Build ────────────────────────────────────────────────────────────────
    if skip_build "$project"; then
        info "  Build: SKIPPED (already verified)"
        skipped_build+=("$name")
        continue
    fi

    do_build "$project" && built+=("$name") || failed+=("$name")
    echo ""

done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "======================================================"
echo "  Summary"
echo "======================================================"
echo ""
[[ ${#skipped_build[@]}   -gt 0 ]] && info "Build skipped (done)  : ${skipped_build[*]}"
[[ ${#built[@]}           -gt 0 ]] && info "Built successfully    : ${built[*]}"
[[ ${#skipped_unknown[@]} -gt 0 ]] && warn "No library detected   : ${skipped_unknown[*]}"
[[ ${#failed[@]}          -gt 0 ]] && error "Failed                : ${failed[*]}"
echo ""

if $DRY_RUN && [[ $(( ${#built[@]} + ${#skipped_build[@]} )) -gt 0 ]]; then
    echo "Re-run with --apply to patch, commit, and build."
    echo ""
fi

if [[ ${#built[@]} -gt 0 ]] && ! $DRY_RUN; then
    echo "Push when ready:"
    for name in "${built[@]}"; do
        echo "  cd ~/git/$name && git push"
    done
    echo ""
fi

[[ ${#failed[@]} -eq 0 ]]
