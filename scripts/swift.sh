#!/bin/zsh
set -euo pipefail
# Some preview SDKs ship without the SwiftUI macro compiler plugin.
# Prefer the installed stable SDK on this machine; otherwise use the default.
SDK_ARGS=()
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  SDK_ARGS=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi
COMMAND="$1"
shift
exec swift "$COMMAND" --build-system native "${SDK_ARGS[@]}" "$@"
