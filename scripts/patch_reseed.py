#!/usr/bin/env python3
"""
patch_reseed.py  <project-root>

Patches EmbeddedI2PRouter.kt in any verzus-family project to replace the
single-host fetchActiveReseedUrls() with the multi-mirror + disk-cache
implementation.  Safe to run repeatedly — exits 0 with a "already patched"
message if the fix is already present.

Exit codes
  0  patched successfully (or already patched)
  1  EmbeddedI2PRouter.kt not found under <project-root>
  2  unexpected file state (anchors missing — manual inspection needed)
"""

import sys
import os
import glob
import shutil

# ── Anchors ──────────────────────────────────────────────────────────────────

# The single-URL constant block we are replacing (const + blank line + docstring
# opening line).  Chosen to be unique and stable across all five projects.
OLD_CONST = '''\
        private const val RESEED_LIST_URL =
            "https://reseed.i2p2.de/reseed-servers.txt"'''

# The broken function signature (no-arg).
OLD_FUN_SIG = '        fun fetchActiveReseedUrls(): String {'

# The broken function body — matches byte-for-byte across all five files.
OLD_FUN_BODY = '''\
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
        }'''

# The old no-arg call site.
OLD_CALL = '        val activeReseedUrls = fetchActiveReseedUrls()'

# ── Replacements ─────────────────────────────────────────────────────────────

NEW_CONSTS = '''\
        /**
         * Mirror list for the I2P project's reseed-server catalogue.
         *
         * Rationale for multiple mirrors:
         *   - reseed.i2p2.de (the canonical host) fails DNS on some networks /
         *     Android DNS resolvers, causing every cold boot to fall back to the
         *     hardcoded URL list.
         *   - Mirrors are tried in shuffled order so no single host is hammered
         *     and a failure on one does not block startup.
         *   - Each URL must return one HTTPS reseed URL per line.
         */
        private val RESEED_LIST_MIRRORS = listOf(
            "https://reseed.i2p2.de/reseed-servers.txt",
            "https://i2p.mooo.com/reseed-servers.txt",
            "https://netdb.i2p2.no/reseed-servers.txt"
        )

        /** File name used to cache a successful fetch inside the app's files dir. */
        private const val RESEED_CACHE_FILE = "reseed_urls.cache"

        /**
         * Maximum age of the on-disk URL cache before a live re-fetch is attempted.
         * 7 days is a reasonable balance: the I2P reseed list is stable week-to-week
         * but does change as servers rotate, so we don't want to cache indefinitely.
         */
        private const val RESEED_CACHE_MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000'''

NEW_FUN_BODY = '''\
        /**
         * Fetch the live reseed-server list, merge with [FALLBACK_RESEED_URLS],
         * shuffle, and return as a comma-separated string for `i2p.reseedURL`.
         *
         * Strategy (in order):
         *  1. If a fresh on-disk cache exists (< 7 days old), use it immediately —
         *     no network required on warm boots.
         *  2. Try each mirror in random order with a short per-host timeout.
         *     The first mirror that returns ≥1 HTTPS URL wins; the result is
         *     merged with [FALLBACK_RESEED_URLS], shuffled, written to disk, and
         *     returned.
         *  3. If all mirrors fail but a stale cache exists, use it rather than
         *     falling back to the fully-hardcoded list.
         *  4. Last resort: return [FALLBACK_RESEED_URLS] shuffled.
         *
         * Must NOT be called on the main thread.
         *
         * @param cacheDir  directory used for the on-disk cache (pass the I2P
         *                  config dir so the cache survives across restarts).
         */
        fun fetchActiveReseedUrls(cacheDir: java.io.File? = null): String {
            val cacheFile = cacheDir?.let { java.io.File(it, RESEED_CACHE_FILE) }
            val fallbackList = FALLBACK_RESEED_URLS.split(",").map { it.trim() }

            // 1. Fresh cache hit — skip the network entirely.
            if (cacheFile != null && cacheFile.exists()) {
                val ageMs = System.currentTimeMillis() - cacheFile.lastModified()
                if (ageMs < RESEED_CACHE_MAX_AGE_MS) {
                    val cached = cacheFile.readText().trim()
                    if (cached.isNotEmpty()) {
                        android.util.Log.i(TAG, "Reseed URLs loaded from cache (age ${ageMs / 3_600_000}h): ${cached.take(60)}...")
                        return cached
                    }
                } else {
                    android.util.Log.d(TAG, "Reseed cache stale (${ageMs / 3_600_000}h old) — attempting live fetch")
                }
            }

            // 2. Try each mirror in shuffled order.
            var fetched: List<String> = emptyList()
            for (mirrorUrl in RESEED_LIST_MIRRORS.shuffled()) {
                try {
                    android.util.Log.d(TAG, "Trying reseed mirror: $mirrorUrl")
                    val conn = (java.net.URL(mirrorUrl).openConnection() as java.net.HttpURLConnection).apply {
                        connectTimeout = 8_000
                        readTimeout    = 8_000
                        requestMethod  = "GET"
                        setRequestProperty("User-Agent", "Verzus/1.0")
                    }
                    val lines = conn.inputStream.bufferedReader().use { it.readLines() }
                    conn.disconnect()

                    fetched = lines.map { it.trim() }.filter { it.startsWith("https://") }
                    if (fetched.isNotEmpty()) {
                        android.util.Log.i(TAG, "Reseed list fetched from $mirrorUrl: ${fetched.size} URLs")
                        break
                    }
                    android.util.Log.w(TAG, "Mirror $mirrorUrl returned no HTTPS URLs — trying next")
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "Mirror $mirrorUrl failed (${e.javaClass.simpleName}: ${e.message}) — trying next")
                }
            }

            if (fetched.isNotEmpty()) {
                // Merge: live list first, then any fallback URLs not already present.
                val merged = (fetched + fallbackList).distinct().shuffled()
                val result = merged.joinToString(",")
                android.util.Log.i(TAG, "Reseed URLs merged: ${fetched.size} live + fallback = ${merged.size} total")

                // Persist to disk so the next cold boot is instant.
                try {
                    cacheFile?.writeText(result)
                    android.util.Log.d(TAG, "Reseed URL cache written to ${cacheFile?.absolutePath}")
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "Could not write reseed cache: ${e.message}")
                }
                return result
            }

            // 3. All mirrors failed — fall back to stale cache if available.
            if (cacheFile != null && cacheFile.exists()) {
                val stale = cacheFile.readText().trim()
                if (stale.isNotEmpty()) {
                    android.util.Log.w(TAG, "All mirrors failed — using stale reseed cache")
                    return stale
                }
            }

            // 4. Last resort: hardcoded list, shuffled so the load is spread.
            android.util.Log.w(TAG, "All mirrors failed and no cache — using hardcoded fallback")
            return fallbackList.shuffled().joinToString(",")
        }'''

NEW_CALL = ('        val activeReseedUrls = fetchActiveReseedUrls(cacheDir = configDir)\n'
            '        // cacheDir passed so successful fetches are persisted; subsequent\n'
            '        // cold boots skip the network if the cache is < 7 days old.')

# ── Sentinel used to detect an already-patched file ──────────────────────────
PATCH_SENTINEL = 'RESEED_LIST_MIRRORS'

# ── Helpers ───────────────────────────────────────────────────────────────────

def find_router_file(project_root: str) -> str | None:
    pattern = os.path.join(project_root, '**', 'EmbeddedI2PRouter.kt')
    matches = glob.glob(pattern, recursive=True)
    return matches[0] if matches else None


def patch(path: str) -> bool:
    """Apply the patch in-place.  Returns True if changes were made."""
    text = open(path, encoding='utf-8').read()

    if PATCH_SENTINEL in text:
        print(f'  [skip] already patched: {path}')
        return False

    # Validate all anchors are present before touching anything.
    missing = []
    for label, anchor in [
        ('OLD_CONST',    OLD_CONST),
        ('OLD_FUN_BODY', OLD_FUN_BODY),
        ('OLD_CALL',     OLD_CALL),
    ]:
        if anchor not in text:
            missing.append(label)

    if missing:
        print(f'  [ERROR] anchors not found in {path}: {missing}')
        print('  Manual inspection required — file not modified.')
        return False

    # Back up original.
    shutil.copy2(path, path + '.bak')

    # 1. Replace the single RESEED_LIST_URL const with the three new consts.
    text = text.replace(OLD_CONST, NEW_CONSTS, 1)

    # 2. Replace the broken function body with the new implementation.
    text = text.replace(OLD_FUN_BODY, NEW_FUN_BODY, 1)

    # 3. Update the call site to pass cacheDir.
    text = text.replace(OLD_CALL, NEW_CALL, 1)

    open(path, 'w', encoding='utf-8').write(text)
    print(f'  [ok]   patched: {path}')
    print(f'         backup:  {path}.bak')
    return True


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <project-root>', file=sys.stderr)
        sys.exit(1)

    project_root = sys.argv[1]
    router_file = find_router_file(project_root)

    if router_file is None:
        print(f'  [ERROR] EmbeddedI2PRouter.kt not found under {project_root}')
        sys.exit(1)

    changed = patch(router_file)
    sys.exit(0)


if __name__ == '__main__':
    main()
