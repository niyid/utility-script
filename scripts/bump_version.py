#!/usr/bin/env python3
"""
bump_version.py  <project-root>

Increments versionCode by 1 and the patch segment of versionName by 1 in
app/build.gradle.kts (or app/build.gradle for Groovy projects).

Supports version name formats:
  "1.2.3"          → "1.2.4"
  "1.2.3-p2p"      → "1.2.4-p2p"
  "1.2.3-SNAPSHOT" → "1.2.4-SNAPSHOT"
  (any trailing -suffix is preserved unchanged)

Prints the old and new values to stdout so the caller can use them in a
commit message.

Exit codes
  0  success
  1  build.gradle not found
  2  versionCode or versionName not found / not parseable
"""

import re
import sys
import os
import shutil

# ── Locating the build file ───────────────────────────────────────────────────

def find_build_file(project_root: str) -> str | None:
    for name in ('app/build.gradle.kts', 'app/build.gradle'):
        path = os.path.join(project_root, name)
        if os.path.isfile(path):
            return path
    return None

# ── Version bumping ───────────────────────────────────────────────────────────

# Matches:  versionCode = 10012
# or:       versionCode 10012   (Groovy)
VERSION_CODE_RE = re.compile(
    r'^(?P<indent>\s*)versionCode\s*=?\s*(?P<code>\d+)',
    re.MULTILINE
)

# Matches:  versionName = "0.1.2-p2p"
# or:       versionName "0.1.2-p2p"  (Groovy)
VERSION_NAME_RE = re.compile(
    r'^(?P<indent>\s*)versionName\s*=?\s*"(?P<name>[^"]+)"',
    re.MULTILINE
)

def bump_patch(version_name: str) -> str:
    """Increment the patch (third) segment; preserve any trailing suffix."""
    # Split off a trailing -suffix (first hyphen after the numeric part)
    m = re.match(r'^(\d+)\.(\d+)\.(\d+)(-.+)?$', version_name)
    if not m:
        raise ValueError(f"Unrecognised versionName format: {version_name!r}")
    major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
    suffix = m.group(4) or ''
    return f"{major}.{minor}.{patch + 1}{suffix}"


def bump(path: str) -> dict:
    """
    Apply the bump in-place.  Returns a dict with old/new values.
    Raises ValueError if patterns are not found.
    """
    text = open(path, encoding='utf-8').read()

    mc = VERSION_CODE_RE.search(text)
    mn = VERSION_NAME_RE.search(text)

    if not mc:
        raise ValueError("versionCode not found in " + path)
    if not mn:
        raise ValueError("versionName not found in " + path)

    old_code = int(mc.group('code'))
    old_name = mn.group('name')

    new_code = old_code + 1
    new_name = bump_patch(old_name)

    # Replace versionCode
    text = VERSION_CODE_RE.sub(
        lambda m: m.group('indent') + f'versionCode = {new_code}',
        text, count=1
    )
    # Replace versionName
    text = VERSION_NAME_RE.sub(
        lambda m: m.group('indent') + f'versionName = "{new_name}"',
        text, count=1
    )

    # Back up then write
    shutil.copy2(path, path + '.bak')
    open(path, 'w', encoding='utf-8').write(text)

    return {
        'old_code': old_code, 'new_code': new_code,
        'old_name': old_name, 'new_name': new_name,
        'file': path,
    }

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <project-root>', file=sys.stderr)
        sys.exit(1)

    project_root = sys.argv[1]
    build_file = find_build_file(project_root)

    if build_file is None:
        print(f'  [ERROR] No app/build.gradle(.kts) found under {project_root}',
              file=sys.stderr)
        sys.exit(1)

    try:
        result = bump(build_file)
    except ValueError as e:
        print(f'  [ERROR] {e}', file=sys.stderr)
        sys.exit(2)

    # Machine-readable output consumed by rebuild_all.sh
    print(f"OLD_CODE={result['old_code']}")
    print(f"NEW_CODE={result['new_code']}")
    print(f"OLD_NAME={result['old_name']}")
    print(f"NEW_NAME={result['new_name']}")
    print(f"BUILD_FILE={result['file']}")


if __name__ == '__main__':
    main()
