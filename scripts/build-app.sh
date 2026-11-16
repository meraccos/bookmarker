#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/swift.sh build -c release --product Bookmarker
BUILD_STAGING=$(mktemp -d -t bookmarker-build)
trap 'rm -rf -- "$BUILD_STAGING"' EXIT
APP="$BUILD_STAGING/Bookmarker.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Bookmarker "$APP/Contents/MacOS/Bookmarker"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Bookmarker</string>
<key>CFBundleIdentifier</key><string>local.bookmarker.app</string>
<key>CFBundleName</key><string>Bookmarker</string>
<key>CFBundleDisplayName</key><string>Bookmarker</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>local.bookmarker.save</string>
<key>CFBundleURLSchemes</key><array><string>bookmarker</string></array>
</dict></array>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
EXTENSION="$APP/Contents/PlugIns/BookmarkerSafari.appex"
mkdir -p "$EXTENSION/Contents/MacOS"
source ./scripts/build-config.sh
clang -fobjc-arc -fapplication-extension -isysroot "$BOOKMARKER_SDK_PATH" -mmacosx-version-min=14.0 \
  -framework SafariServices -framework AppKit -framework Foundation \
  -Wl,-e,_NSExtensionMain SafariExtension/SafariExtensionHandler.m \
  -o "$EXTENSION/Contents/MacOS/BookmarkerSafari"
cp SafariExtension/Info.plist "$EXTENSION/Contents/Info.plist"
mkdir -p "$EXTENSION/Contents/Resources"
cp SafariExtension/Resources/* "$EXTENSION/Contents/Resources/"
SIGNING_IDENTITY="${BOOKMARKER_SIGNING_IDENTITY:--}"
xattr -cr "$APP"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements SafariExtension/entitlements.plist "$EXTENSION"
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$PWD/dist"
ditto --norsrc --noextattr "$APP" "$PWD/dist/Bookmarker.app"
# A file provider may restore FinderInfo immediately after publishing the bundle.
for attempt in 1 2 3; do
  xattr -cr "$PWD/dist/Bookmarker.app"
  if codesign --verify --deep --strict "$PWD/dist/Bookmarker.app" 2>/dev/null; then
    break
  fi
done
codesign --verify --deep --strict "$PWD/dist/Bookmarker.app"
echo "Built $PWD/dist/Bookmarker.app"
