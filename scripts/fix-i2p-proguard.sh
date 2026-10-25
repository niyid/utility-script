#!/usr/bin/env bash
# fix-i2p-proguard.sh
# Audits and patches proguard-rules.pro in every project that uses I2P.
# Safe to re-run: skips projects that already have the rules.
#
# Usage:
#   ./fix-i2p-proguard.sh              # dry-run: shows what would change
#   ./fix-i2p-proguard.sh --apply      # writes the changes

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

PROJECTS=(
    "$HOME/git/verzus-p2p"
    "$HOME/git/ajo-android-p2p"
    "$HOME/git/scrowit-android-p2p"
)

DRY_RUN=true
[[ "${1:-}" == "--apply" ]] && DRY_RUN=false

# ── I2P keep rules to inject ──────────────────────────────────────────────────
# Sentinel: checked before injecting to avoid duplicates
SENTINEL="# --- I2P Router keep rules"

# read -r -d '' always exits 1 at EOF; || true prevents set -e from killing script
read -r -d '' I2P_RULES << 'EOF' || true

# --- I2P Router keep rules (injected by fix-i2p-proguard.sh) -----------------
# All net.i2p classes are accessed via reflection in EmbeddedI2PRouter.
# Without these rules R8 renames/strips constructors and causes
# NoSuchMethodException at runtime (symptom: net.i2p.router.a.<init> []).

# Preserve all I2P classes and members
-keep class net.i2p.** { *; }
-dontwarn net.i2p.**

# Router constructors tried in createRouter() fallback chain
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

# SAMBridge constructors tried in startSAMBridge() fallback chain
-keepclassmembers class net.i2p.sam.SAMBridge {
    public <init>(java.lang.String, int, boolean, java.util.Properties, java.lang.String, java.io.File, net.i2p.sam.SAMSecureSessionInterface);
    public <init>(java.lang.String, int, java.util.Properties);
    public <init>();
    public void startListening();
}

# RouterContext -- constructed internally by Router, must keep its name
-keep class net.i2p.router.RouterContext { *; }

# SAMSecureSessionInterface -- referenced in SAMBridge 7-arg constructor
-keep interface net.i2p.sam.SAMSecureSessionInterface { *; }
# -----------------------------------------------------------------------------
EOF

# ── Helpers ───────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

uses_i2p() {
    local gradle="$1/app/build.gradle.kts"
    [[ -f "$gradle" ]] && grep -qE "i2p-android-client|router\.jar|net\.i2p" "$gradle"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
echo "======================================================"
echo "  I2P ProGuard Rule Auditor"
if $DRY_RUN; then
    echo "  Mode: DRY-RUN (pass --apply to write changes)"
else
    echo "  Mode: APPLY"
fi
echo "======================================================"
echo ""

found_projects=()
skipped_not_i2p=()
skipped_missing=()
already_ok=()
patched=()
failed=()

for project in "${PROJECTS[@]}"; do

    # ── Does the project dir exist? ───────────────────────────────────────────
    if [[ ! -d "$project" ]]; then
        warn "Project not found, skipping: $project"
        skipped_missing+=("$project")
        continue
    fi

    # ── Does it declare an I2P dependency? ───────────────────────────────────
    if ! uses_i2p "$project"; then
        info "No I2P dependency detected, skipping: $project"
        skipped_not_i2p+=("$project")
        continue
    fi

    found_projects+=("$project")
    proguard="$project/app/proguard-rules.pro"

    # ── Does proguard-rules.pro exist? ───────────────────────────────────────
    if [[ ! -f "$proguard" ]]; then
        warn "proguard-rules.pro missing in $project"
        if $DRY_RUN; then
            warn "[DRY-RUN] Would create: $proguard"
        else
            echo "$I2P_RULES" > "$proguard"
            info "Created: $proguard"
            patched+=("$project")
        fi
        continue
    fi

    # ── Already patched? ─────────────────────────────────────────────────────
    if grep -qF "$SENTINEL" "$proguard"; then
        info "Already has I2P rules: $(basename $project)"
        already_ok+=("$project")

        # Check for common gaps even if sentinel present
        missing_rules=()
        grep -qF "net.i2p.router.RouterContext"          "$proguard" || missing_rules+=("RouterContext")
        grep -qF "net.i2p.sam.SAMSecureSessionInterface" "$proguard" || missing_rules+=("SAMSecureSessionInterface")
        grep -qF "net.i2p.sam.SAMBridge"                 "$proguard" || missing_rules+=("SAMBridge")

        if [[ ${#missing_rules[@]} -gt 0 ]]; then
            warn "  Rules present but incomplete. Missing: ${missing_rules[*]}"
        else
            info "  All required rules present."
        fi
        continue
    fi

    # ── Needs patching ───────────────────────────────────────────────────────
    echo ""
    warn "Missing I2P rules: $(basename $project)/app/proguard-rules.pro"

    # Warn if release minification is enabled
    if grep -q "isMinifyEnabled = true" "$project/app/build.gradle.kts" 2>/dev/null; then
        warn "  isMinifyEnabled = true -- rules are REQUIRED or Router will crash at runtime"
    fi

    if $DRY_RUN; then
        warn "[DRY-RUN] Would append to: $proguard"
        echo "--- Rules that would be added ---"
        echo "$I2P_RULES"
        echo "---------------------------------"
    else
        printf '\n%s\n' "$I2P_RULES" >> "$proguard"
        if grep -qF "$SENTINEL" "$proguard"; then
            info "Patched: $proguard"
            patched+=("$project")
        else
            error "Patch failed (sentinel not found after write): $proguard"
            failed+=("$project")
        fi
    fi

done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "======================================================"
echo "  Summary"
echo "======================================================"
echo ""
[[ ${#found_projects[@]}  -gt 0 ]] && info "I2P projects found   : ${#found_projects[@]} -- ${found_projects[*]##*/}"
[[ ${#skipped_missing[@]} -gt 0 ]] && warn "Project dirs missing : ${skipped_missing[*]##*/}"
[[ ${#skipped_not_i2p[@]} -gt 0 ]] && info "No I2P (skipped)     : ${skipped_not_i2p[*]##*/}"
[[ ${#already_ok[@]}      -gt 0 ]] && info "Already up to date   : ${already_ok[*]##*/}"
[[ ${#patched[@]}         -gt 0 ]] && info "Patched              : ${patched[*]##*/}"
[[ ${#failed[@]}          -gt 0 ]] && error "Failed               : ${failed[*]##*/}"
echo ""

if $DRY_RUN && [[ ${#found_projects[@]} -gt 0 ]]; then
    echo "Re-run with --apply to write changes."
    echo ""
fi

if [[ ${#patched[@]} -gt 0 ]]; then
    echo "Next steps:"
    for p in "${patched[@]}"; do
        echo "  cd $p && git add app/proguard-rules.pro && git commit -m 'fix: add I2P R8 keep rules to prevent NoSuchMethodException'"
    done
    echo ""
fi

[[ ${#failed[@]} -eq 0 ]]
