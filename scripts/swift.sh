#!/bin/zsh
set -euo pipefail
# Some preview SDKs ship without the SwiftUI macro compiler plugin.
# Prefer the installed stable SDK on this machine; otherwise use the default.
source "${0:A:h}/build-config.sh"
COMMAND="$1"
shift
exec swift "$COMMAND" --build-system native --sdk "$BOOKMARKER_SDK_PATH" "$@"
