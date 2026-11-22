#!/bin/sh
# Build Isle (Release) and install it to /Applications, replacing the running copy.
set -eu
cd "$(dirname "$0")/.."

echo "› generating project"
xcodegen generate >/dev/null

echo "› building Release"
xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Release \
  -derivedDataPath build/release build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
APP="build/release/Build/Products/Release/Isle.app"
[ -d "$APP" ] || { echo "build failed"; exit 1; }

echo "› quitting running Isle"
pkill -x Isle 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Isle >/dev/null || break; sleep 0.5; done
sleep 0.5

echo "› installing to /Applications/Isle.app"
rm -rf /Applications/Isle.app
ditto "$APP" /Applications/Isle.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Isle.app

echo "› launching"
open /Applications/Isle.app
echo "✓ installed: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Isle.app/Contents/Info.plist)"
