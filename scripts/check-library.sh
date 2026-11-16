#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
./scripts/swift.sh build --product BookmarkChecks
BUILD_DIR=$(./scripts/swift.sh build --show-bin-path)
source ./scripts/build-config.sh
# Compile the actual persistence and reader sources against an isolated temporary library.
swiftc -whole-module-optimization -swift-version 6 -parse-as-library -sdk "$BOOKMARKER_SDK_PATH" \
  -I "$BUILD_DIR/Modules" "$BUILD_DIR"/BookmarkCore.build/*.o \
  Sources/Bookmarker/BookmarkFiles.swift Sources/Bookmarker/LocalReadingCopies.swift Sources/Bookmarker/LibraryBackup.swift Sources/Bookmarker/LibraryCloudSetup.swift Sources/Bookmarker/LibrarySyncStatus.swift Sources/Bookmarker/CoordinatedFiles.swift Sources/Bookmarker/Library.swift Sources/Bookmarker/WebpageReader.swift \
  Tests/LibraryChecks/LibraryChecks.swift -o "$BUILD_DIR/LibraryChecks"
"$BUILD_DIR/LibraryChecks"
