#!/bin/zsh
# Shared SDK selection for Swift, integration checks and the Safari extension.
BOOKMARKER_SDK_PATH=$(xcrun --show-sdk-path)
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  BOOKMARKER_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
