#!/usr/bin/env bash
# Captures only what the render tool actually needs from the three repos
# into one zip, small enough to upload -- no .git history, no Unity
# Library/Temp/meta cruft, no previous render output.
#
# Usage:
#   cd ~/Downloads   (or anywhere)
#   ./capture_render_assets.sh
#
# Env overrides:
#   GIT_REPOS_DIR   parent dir containing the three repos (default: ~/git)
#   OUT_ZIP         output zip path (default: ./render_assets_capture.zip)

set -euo pipefail

GIT_REPOS_DIR="${GIT_REPOS_DIR:-$HOME/git}"
OUT_ZIP="${OUT_ZIP:-$(pwd)/render_assets_capture.zip}"

OGBOJUODE_DIR="$GIT_REPOS_DIR/ogbojuode-3d"
IREKE_DIR="$GIT_REPOS_DIR/irekeonibudo-3d"
TOOL_DIR="$GIT_REPOS_DIR/fagunwa-duel-render-tool"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "== capturing render assets =="
echo "repos dir: $GIT_REPOS_DIR"
echo "staging:   $STAGE"
echo "output:    $OUT_ZIP"
echo

missing=0
for d in "$OGBOJUODE_DIR" "$IREKE_DIR" "$TOOL_DIR"; do
    if [ ! -d "$d" ]; then
        echo "ERROR: not found: $d"
        missing=1
    fi
done
[ "$missing" = 1 ] && { echo "Set GIT_REPOS_DIR if your repos live elsewhere."; exit 1; }

# ---- 1. character + prop FBX from both game repos ----
# (skips Unity Library/, Temp/, obj/, .git/, *.meta, textures, etc --
# the render tool only ever reads the .fbx files themselves)
for game in ogbojuode-3d irekeonibudo-3d; do
    src="$GIT_REPOS_DIR/$game/Assets/Models"
    dst="$STAGE/$game/Assets/Models"
    if [ -d "$src" ]; then
        mkdir -p "$dst"
        find "$src" -type f -iname '*.fbx' -print0 \
          | while IFS= read -r -d '' f; do
                rel="${f#"$src"/}"
                mkdir -p "$dst/$(dirname "$rel")"
                cp "$f" "$dst/$rel"
            done
        n=$(find "$dst" -type f -iname '*.fbx' | wc -l)
        echo "$game: captured $n .fbx file(s)"
    else
        echo "$game: WARNING, $src not found, skipping"
    fi
done

# ---- 2. render tool source (no output/, converted_props/, __pycache__, .git) ----
tool_src="$TOOL_DIR/blender_render_tool"
tool_dst="$STAGE/fagunwa-duel-render-tool/blender_render_tool"
if [ -d "$tool_src" ]; then
    mkdir -p "$tool_dst"
    find "$tool_src" -maxdepth 1 -type f \( -iname '*.py' -o -iname '*.md' \) \
      -exec cp {} "$tool_dst/" \;
    n=$(find "$tool_dst" -type f | wc -l)
    echo "fagunwa-duel-render-tool: captured $n file(s)"
else
    echo "WARNING: $tool_src not found, skipping"
fi

# ---- 3. zip it ----
rm -f "$OUT_ZIP"
( cd "$STAGE" && zip -rq "$OUT_ZIP" . )

echo
echo "Done: $OUT_ZIP ($(du -h "$OUT_ZIP" | cut -f1))"
echo "Upload that file -- it has everything needed to re-run the render,"
echo "at a fraction of the full repos' size (no .git history, no Unity"
echo "project files, no previous renders)."
