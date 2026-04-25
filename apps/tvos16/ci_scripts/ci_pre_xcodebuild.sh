#!/bin/sh
# Xcode Cloud pre-build: build libprojectM xcframework if not already present.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
XCFW="$REPO_ROOT/apps/tvos16/Frameworks/libprojectM.xcframework"

if [ -d "$XCFW" ]; then
  echo "xcframework already present, skipping build"
  exit 0
fi

echo "Building libprojectM xcframework..."

# cmake is not pre-installed in Xcode Cloud — install via Homebrew
if ! command -v cmake >/dev/null 2>&1; then
  echo "Installing cmake..."
  brew install cmake
fi

bash "$REPO_ROOT/apps/tvos16/scripts/build-libprojectm-xcframework.sh"
