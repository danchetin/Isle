#!/bin/sh
# Build a downloadable Isle-<version>.dmg in build/dist.
#
# With a "Developer ID Application" certificate in the keychain the app and the DMG are
# signed with it; with a notarytool profile (default name "isle", override NOTARY_PROFILE)
# the DMG is also notarized and stapled, so it opens on any Mac without warnings.
# Without them it falls back to the development certificate and says what's missing.
#
# One-time notarization setup (app-specific password from account.apple.com):
#   xcrun notarytool store-credentials isle --apple-id <you@example.com> --team-id XL2KLP55AX
set -eu
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
PROFILE=${NOTARY_PROFILE:-isle}
DERIVED=build/dist-build
DIST=build/dist
DMG="$DIST/Isle-$VERSION.dmg"
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)

echo "› Isle $VERSION"
xcodegen generate >/dev/null

echo "› building Release"
if [ -n "$IDENTITY" ]; then
  echo "  signing with: $IDENTITY"
  xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" build 2>&1 \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
else
  echo "  ⚠ no Developer ID Application certificate: using Apple Development."
  echo "    Other Macs will block the app until «Open Anyway» in Privacy & Security."
  xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" build 2>&1 \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
fi
APP="$DERIVED/Build/Products/Release/Isle.app"
[ -d "$APP" ] || { echo "build failed"; exit 1; }
codesign --verify --deep --strict "$APP"

echo "› packing DMG"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Isle.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "Isle" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null 2>&1
[ -f "$DMG" ] || { echo "hdiutil failed"; exit 1; }

if [ -n "$IDENTITY" ]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "› notarizing (a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
  else
    echo "  ⚠ no notarytool profile \"$PROFILE\": DMG signed but not notarized (see the header of this script)."
  fi
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
