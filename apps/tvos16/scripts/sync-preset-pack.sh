#!/usr/bin/env bash
# Sync the curated Milkdrop preset pack from ~/Music/projectm-presets
# into apps/tvos/Resources/presets/ for bundling into the tvOS app.
#
# Must be run before every Archive. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SRC="${HOME}/Music/projectm-presets/"
DST="${REPO_ROOT}/apps/tvos/Resources/presets/"

if [[ ! -d "${SRC}" ]]; then
    echo "ERROR: preset pack not found at ${SRC}" >&2
    echo "Clone it with: git clone https://github.com/projectM-visualizer/presets-cream-of-the-crop ${SRC}" >&2
    exit 1
fi

mkdir -p "${DST}"

# --delete removes orphaned files in the destination (idempotent).
# Exclude dotfiles (including .git) so we don't ship the preset repo's .git into the app bundle.
rsync -a --delete \
    --exclude='.git' \
    --exclude='.gitignore' \
    --exclude='.DS_Store' \
    "${SRC}" "${DST}"

# Keep a marker file tracked in git so the directory exists.
touch "${DST}.gitkeep"

preset_count=$(find "${DST}" -name '*.milk' -type f | wc -l | tr -d ' ')
echo "Preset pack synced: ${preset_count} .milk files in ${DST}"
