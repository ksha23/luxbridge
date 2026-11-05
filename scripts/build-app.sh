#!/bin/bash
# Builds build/LuxBridge.app (Apple Silicon).
#
#   SIGN_IDENTITY   codesign identity, for example "Developer ID Application: Name (TEAMID)".
#                   Without it the app is signed ad hoc, which is fine on the machine that built it.
#   NOTARY_PROFILE  a notarytool keychain profile. With it (and SIGN_IDENTITY) the app is
#                   notarized and stapled, and build/LuxBridge.zip is ready to share.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
bin_dir=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "build/LuxBridge.app"
mkdir -p "build/LuxBridge.app/Contents/MacOS" "build/LuxBridge.app/Contents/Resources"
cp "$bin_dir/LuxBridge" "build/LuxBridge.app/Contents/MacOS/LuxBridge"
cp "Resources/Info.plist" "build/LuxBridge.app/Contents/Info.plist"
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "build/LuxBridge.app/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "build/LuxBridge.app/Contents/Info.plist"
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "build/LuxBridge.app"
else
    codesign --force --sign - "build/LuxBridge.app"
fi
codesign --verify --strict "build/LuxBridge.app"

if [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]]; then
    rm -f "build/LuxBridge.zip"
    ditto -c -k --keepParent "build/LuxBridge.app" "build/LuxBridge.zip"
    xcrun notarytool submit "build/LuxBridge.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "build/LuxBridge.app"
    rm -f "build/LuxBridge.zip"
    ditto -c -k --keepParent "build/LuxBridge.app" "build/LuxBridge.zip"
fi

echo "Built build/LuxBridge.app"
