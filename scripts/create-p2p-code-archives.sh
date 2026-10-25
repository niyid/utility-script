#!/usr/bin/env bash
#
# create-p2p-code-archives.sh
#
# Creates one code-only zip per project under ~/git (or a directory you pass in).
# Pulls source/config files only (kt, java, xml, gradle, properties, etc.) and
# skips build/, logs/, .git/, .gradle/, .idea/, node_modules/, and any binaries
# or docs (png, html, log, etc.) that live alongside the code.
#
# Usage:
#   ./create-p2p-code-archives.sh                 # BASE_DIR=~/git, OUT_DIR=~/git/code-archives
#   ./create-p2p-code-archives.sh /path/to/git     # custom BASE_DIR
#   ./create-p2p-code-archives.sh /path/to/git /path/to/out   # custom BASE_DIR + OUT_DIR
#
set -euo pipefail

BASE_DIR="${1:-$HOME/git}"
OUT_DIR="${2:-$BASE_DIR/code-archives}"
mkdir -p "$OUT_DIR"

# Projects to archive.
# kotlin-networking-p2p is intentionally excluded.
PROJECTS=(
  ajo-android-p2p
  buzzr-p2p
  kabu-kabu-p2p
  scrowit-android-p2p
  sixdegrees-p2p
  verzus-p2p
)

# Extensions treated as "code" for these repos (derived from what's actually
# in the projects: Kotlin/Java Android sources, Gradle build files, Android
# XML resources/manifests, proguard rules, protobufs, config/docs).
INCLUDE=(
  "*.kt" "*.kts" "*.java" "*.xml" "*.gradle"
  "*.properties" "*.pro" "*.proto" "*.md"
  "*.yaml" "*.yml" "*.sh" "*.py" "*.json"
)

# Directories to skip no matter where they appear in the tree.
EXCLUDE=(
  "*/build/*" "*/.gradle/*" "*/.git/*" "*/.idea/*"
  "*/logs/*" "*/node_modules/*"
  "local.properties" "*/local.properties"
)

echo "Base dir: $BASE_DIR"
echo "Output dir: $OUT_DIR"
echo

for proj in "${PROJECTS[@]}"; do
  src="$BASE_DIR/$proj"

  if [[ ! -d "$src" ]]; then
    echo "SKIP: $proj (directory not found at $src)" >&2
    continue
  fi

  out="$OUT_DIR/${proj}.zip"
  rm -f "$out"

  echo "Archiving $proj -> $out"
  (
    cd "$src"
    zip -qr "$out" . -i "${INCLUDE[@]}" -x "${EXCLUDE[@]}"
  )
done

echo
echo "Done. Archives written to: $OUT_DIR"
ls -lh "$OUT_DIR"
