#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/swift.sh build -c release --product Bookmarker
APP="${BOOKMARKER_APP_PATH:-$PWD/dist/Bookmarker.app}"
APP_VERSION="${BOOKMARKER_VERSION:-0.3.0}"
BUILD_NUMBER="${BOOKMARKER_BUILD_NUMBER:-3}"
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
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>__APP_VERSION__</string>
<key>CFBundleVersion</key><string>__BUILD_NUMBER__</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>local.bookmarker.save</string>
<key>CFBundleURLSchemes</key><array><string>bookmarker</string></array>
</dict></array>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
sed -i '' -e "s/__APP_VERSION__/$APP_VERSION/" -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/" "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
EXTENSION="$APP/Contents/PlugIns/BookmarkerSafari.appex"
mkdir -p "$EXTENSION/Contents/MacOS"
SDK_PATH=$(xcrun --show-sdk-path)
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
clang -fobjc-arc -fapplication-extension -isysroot "$SDK_PATH" -mmacosx-version-min=14.0 \
  -framework SafariServices -framework AppKit -framework Foundation \
  -Wl,-e,_NSExtensionMain SafariExtension/SafariExtensionHandler.m \
  -o "$EXTENSION/Contents/MacOS/BookmarkerSafari"
cp SafariExtension/Info.plist "$EXTENSION/Contents/Info.plist"
mkdir -p "$EXTENSION/Contents/Resources"
cp SafariExtension/Resources/* "$EXTENSION/Contents/Resources/"
SIGNING_IDENTITY="${BOOKMARKER_SIGNING_IDENTITY:--}"
# Finder/File Provider metadata on generated bundles can make codesign fail with
# "resource fork, Finder information, or similar detritus not allowed".
# Clear extended attributes only from the generated app, never the sources.
xattr -cr "$APP"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements SafariExtension/entitlements.plist "$EXTENSION"
xattr -cr "$APP"
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
