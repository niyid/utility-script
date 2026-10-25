#!/usr/bin/env bash
# =============================================================================
# patch_i2p_reseed.sh
#
# Finds every EmbeddedI2PRouter.kt under the listed projects and patches those
# that still use the hardcoded RESEED_URLS constant:
#   1. Rename  RESEED_URLS → FALLBACK_RESEED_URLS  (everywhere in the file)
#   2. Insert  fetchActiveReseedUrls() after the FALLBACK_RESEED_URLS block
#   3. Update  the System.setProperty call site to use fetchActiveReseedUrls()
#
# Already-patched files are skipped. Each project gets one git commit.
# =============================================================================

set -uo pipefail   # NOTE: -e intentionally omitted; errors handled manually

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*"; }

PROJECTS=(
    "$HOME/git/sixdegrees-p2p"
    "$HOME/git/buzzr-p2p"
    "$HOME/git/scrowit-android-p2p"
    "$HOME/git/ajo-android-p2p"
)

# ── Write Kotlin method block to a temp file ----------------------------------
# (Using a temp file avoids the "read -r -d '' exits 1" problem that causes
#  set -uo pipefail to kill the script silently before printing anything.)
FETCH_METHOD_FILE=$(mktemp /tmp/fetch_method_XXXXXX.kt)
trap 'rm -f "$FETCH_METHOD_FILE"' EXIT

cat > "$FETCH_METHOD_FILE" << 'KOTLIN_EOF'

        /**
         * URL of the I2P project's authoritative reseed-server list.
         * Returns one HTTPS reseed URL per line.  Fetched at startup so the
         * embedded router automatically discovers new servers or drops dead ones
         * without requiring an app update.
         */
        private const val RESEED_LIST_URL =
            "https://reseed.i2p2.de/reseed-servers.txt"

        /**
         * Fetch the live reseed-server list from the I2P project, merge with
         * [FALLBACK_RESEED_URLS], and return as a comma-separated string suitable
         * for the `i2p.reseedURL` system property.
         *
         * Falls back to [FALLBACK_RESEED_URLS] silently on any network error —
         * the router will still start, just without newly-added servers.
         *
         * Must NOT be called on the main thread.
         */
        fun fetchActiveReseedUrls(): String {
            return try {
                val url = java.net.URL(RESEED_LIST_URL)
                val conn = (url.openConnection() as java.net.HttpURLConnection).apply {
                    connectTimeout = 8_000
                    readTimeout    = 8_000
                    requestMethod  = "GET"
                }
                val fetched: List<String> = conn.inputStream.bufferedReader().use { reader ->
                    reader.readLines()
                        .map { it.trim() }
                        .filter { it.startsWith("https://") }
                }
                conn.disconnect()

                if (fetched.isEmpty()) {
                    android.util.Log.w(TAG, "Reseed list fetch returned no HTTPS URLs — using fallback")
                    return FALLBACK_RESEED_URLS
                }

                // Merge: live list first (newer servers), then any fallback URLs not
                // already present (so well-known reliable servers are always included).
                val fallbackList = FALLBACK_RESEED_URLS.split(",").map { it.trim() }
                val merged = (fetched + fallbackList).distinct()
                val result = merged.joinToString(",")
                android.util.Log.i(TAG, "Reseed URLs updated: ${fetched.size} live + fallback = ${merged.size} total")
                result
            } catch (e: Exception) {
                android.util.Log.w(TAG, "Could not fetch live reseed list (${e.message}) — using hardcoded fallback")
                FALLBACK_RESEED_URLS
            }
        }
KOTLIN_EOF

# ── patch_file() --------------------------------------------------------------
patch_file() {
    local file="$1"
    local tmp="${file}.patch_tmp"

    # Guard: skip if already patched
    if grep -q "fetchActiveReseedUrls" "$file"; then
        warn "Already patched, skipping: $file"
        return 1
    fi

    # Guard: must contain RESEED_URLS to be patchable
    if ! grep -q "private const val RESEED_URLS" "$file"; then
        warn "No RESEED_URLS constant found, skipping: $file"
        return 1
    fi

    cp "$file" "$tmp"

    # ── Step 1: rename RESEED_URLS → FALLBACK_RESEED_URLS --------------------
    sed -i 's/\bRESEED_URLS\b/FALLBACK_RESEED_URLS/g' "$tmp"
    info "  Step 1 done: renamed RESEED_URLS → FALLBACK_RESEED_URLS"

    # ── Step 2: insert fetchActiveReseedUrls() after the constant block -------
    python3 - "$tmp" "$FETCH_METHOD_FILE" << 'PY_EOF'
import sys, pathlib

target_file = pathlib.Path(sys.argv[1])
method_text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

lines    = target_file.read_text(encoding="utf-8").splitlines(keepends=True)
out      = []
inserted = False

for i, line in enumerate(lines):
    out.append(line)
    # Anchor: last line of the FALLBACK_RESEED_URLS block —
    # a line containing a reseed URL that ends with a plain closing quote
    # (no trailing comma or + continuation).
    stripped = line.rstrip()
    if (not inserted
            and stripped.endswith('"')
            and "reseed" in line.lower()
            and not stripped.endswith('",')
            and not stripped.endswith('" +')):
        preceding = "".join(lines[:i+1])
        if ("FALLBACK_RESEED_URLS" in preceding
                and "private const val FALLBACK_RESEED_URLS" in preceding):
            out.append(method_text + "\n")
            inserted = True

if not inserted:
    # Fallback: insert before the last lone closing brace in the file
    for i in range(len(out) - 1, -1, -1):
        if out[i].strip() == "}" and i > 10:
            out.insert(i, method_text + "\n")
            inserted = True
            break

target_file.write_text("".join(out), encoding="utf-8")
sys.exit(0 if inserted else 2)
PY_EOF
    local py1=$?
    if [[ $py1 -ne 0 ]]; then
        err "  Step 2 failed (exit $py1): could not insert method"
        cp "$tmp" "${file}.patch_failed"
        rm -f "$tmp"
        return 1
    fi
    info "  Step 2 done: inserted fetchActiveReseedUrls()"

    # ── Step 3: update the System.setProperty call site -----------------------
    python3 - "$tmp" << 'PY_EOF2'
import sys, re, pathlib

f    = pathlib.Path(sys.argv[1])
text = f.read_text(encoding="utf-8")

pattern = re.compile(
    r'^(?P<indent>[ \t]*)System\.setProperty\("i2p\.reseedURL",\s*FALLBACK_RESEED_URLS\)',
    re.MULTILINE
)

def replacement(m):
    ind = m.group("indent")
    return (
        f'{ind}val activeReseedUrls = fetchActiveReseedUrls()\n'
        f'{ind}System.setProperty("i2p.reseedURL", activeReseedUrls)'
    )

new_text, count = pattern.subn(replacement, text)
if count == 0:
    print("WARN: call-site pattern not found — may need manual check", file=sys.stderr)
else:
    # Fix any adjacent Log line still referencing the old constant name
    new_text = new_text.replace(
        '${FALLBACK_RESEED_URLS.take(',
        '${activeReseedUrls.take('
    )

f.write_text(new_text, encoding="utf-8")
sys.exit(0)
PY_EOF2
    info "  Step 3 done: updated call site"

    # ── Validate --------------------------------------------------------------
    local valid=true
    grep -q "FALLBACK_RESEED_URLS"            "$tmp" || { err "  FALLBACK_RESEED_URLS missing";       valid=false; }
    grep -q "fun fetchActiveReseedUrls"       "$tmp" || { err "  fetchActiveReseedUrls() missing";    valid=false; }
    grep -q "val activeReseedUrls"            "$tmp" || { err "  activeReseedUrls call-site missing"; valid=false; }
    if grep -q "private const val RESEED_URLS " "$tmp"; then
        err "  Old RESEED_URLS constant still present"
        valid=false
    fi

    if [[ "$valid" == false ]]; then
        err "  Validation failed — original preserved, failed patch at ${file}.patch_failed"
        cp "$tmp" "${file}.patch_failed"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$file"
    ok "  Patched and validated: $(basename "$file")"
    return 0
}

# ── Main loop -----------------------------------------------------------------
overall_changed=false

for project in "${PROJECTS[@]}"; do
    echo ""
    info "════════════════════════════════════════════════════════"
    info "Project: $project"

    if [[ ! -d "$project" ]]; then
        warn "Directory not found, skipping."
        continue
    fi

    mapfile -t router_files < <(find "$project" -name "EmbeddedI2PRouter.kt" 2>/dev/null)

    if [[ ${#router_files[@]} -eq 0 ]]; then
        warn "No EmbeddedI2PRouter.kt found in $project"
        continue
    fi

    project_changed=false
    for router_file in "${router_files[@]}"; do
        info "Found: $router_file"
        if patch_file "$router_file"; then
            project_changed=true
        fi
    done

    if [[ "$project_changed" == true ]]; then
        pushd "$project" > /dev/null
        git add -A
        git commit -m "feat: fetch live I2P reseed-server list at startup

- Rename RESEED_URLS → FALLBACK_RESEED_URLS
- Add fetchActiveReseedUrls(): fetches reseed.i2p2.de/reseed-servers.txt,
  merges with fallback list, falls back silently on network error
- startI2PRouter() uses fetchActiveReseedUrls() so the router adapts to
  server changes without requiring an app update"
        ok "Committed in $project"
        popd > /dev/null
        overall_changed=true
    else
        info "No changes to commit in $project"
    fi
done

echo ""
info "════════════════════════════════════════════════════════"
if [[ "$overall_changed" == true ]]; then
    ok "All done."
else
    info "No projects were modified."
fi
