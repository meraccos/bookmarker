#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
./scripts/swift.sh build --product BookmarkChecks
BUILD_DIR=$(./scripts/swift.sh build --show-bin-path)
SDK_PATH=$(xcrun --show-sdk-path)
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
# Compile the actual persistence and reader sources against an isolated temporary library.
swiftc -whole-module-optimization -swift-version 6 -parse-as-library -sdk "$SDK_PATH" \
  -I "$BUILD_DIR/Modules" "$BUILD_DIR"/BookmarkCore.build/*.o \
  Sources/Bookmarker/LocalReadingCopies.swift Sources/Bookmarker/LibraryBackup.swift Sources/Bookmarker/LibraryCloudSetup.swift Sources/Bookmarker/LibrarySyncStatus.swift Sources/Bookmarker/CoordinatedFiles.swift Sources/Bookmarker/Library.swift Sources/Bookmarker/WebpageReader.swift \
  Tests/LibraryChecks/LibraryChecks.swift -o "$BUILD_DIR/LibraryChecks"
"$BUILD_DIR/LibraryChecks"
