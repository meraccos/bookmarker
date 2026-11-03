#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${BOOKMARKER_VERSION:-0.3.0}"
OUTPUT="$PWD/dist/Bookmarker-$VERSION.zip"
STAGING_DIR=$(mktemp -d /private/tmp/bookmarker-release.XXXXXX)
STAGED_APP="$STAGING_DIR/Bookmarker.app"
trap 'rm -rf "$STAGING_DIR"' EXIT

BOOKMARKER_VERSION="$VERSION" BOOKMARKER_APP_PATH="$STAGED_APP" ./scripts/build-app.sh
mkdir -p "$PWD/dist"
ditto -c -k --keepParent "$STAGED_APP" "$OUTPUT"
(
  cd "$PWD/dist"
  shasum -a 256 "Bookmarker-$VERSION.zip" > "Bookmarker-$VERSION.zip.sha256"
)

echo "Created $OUTPUT"
echo "Created $OUTPUT.sha256"
