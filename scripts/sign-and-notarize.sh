#!/bin/bash
# Builds Universal Converter with a Developer ID signature, sends it to Apple for notarization, and staples the ticket,
# so the app opens on any Mac without a Gatekeeper warning. This is the way to share the app outside the Mac App Store.
#
# You need (once):
#   1. Membership in the Apple Developer Program, and a "Developer ID Application" certificate in your keychain
#      (Xcode -> Settings -> Accounts -> Manage Certificates -> + -> Developer ID Application).
#   2. A saved notarization login:
#        xcrun notarytool store-credentials "converter-notary" --apple-id YOU@example.com --team-id TEAMID --password APP-SPECIFIC-PASSWORD
#      (create the app-specific password at appleid.apple.com).
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/sign-and-notarize.sh [notary-profile]
#
# The result is build/Universal Converter.zip. This script has not been run yet: it needs a paid Apple Developer account.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?Set DEVELOPER_ID to the name of your Developer ID Application certificate}"
PROFILE="${1:-converter-notary}"

xcodegen generate >/dev/null
mkdir -p build
echo "Building and signing with: $DEVELOPER_ID"
xcodebuild -project "Universal Converter.xcodeproj" -scheme "Universal Converter" -configuration Release \
  -derivedDataPath build/xcode CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" build >build/xcodebuild.log 2>&1 \
  || { grep -E "error:" build/xcodebuild.log | tail -20; echo "The build failed. See build/xcodebuild.log"; exit 1; }

APP="build/Universal Converter.app"
rm -rf "$APP"
cp -R "build/xcode/Build/Products/Release/Universal Converter.app" "$APP"

# The signature must be valid, use the hardened runtime and carry a secure timestamp, or Apple rejects it.
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -q "flags=.*runtime" || { echo "The hardened runtime is not on"; exit 1; }

ZIP="build/Universal Converter.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Sending to Apple for notarization. This usually takes a few minutes."
# notarytool can finish without an error code when Apple rejects the app, so the verdict is read from its answer.
RESULT="build/notarization.json"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json >"$RESULT" \
  || { cat "$RESULT" 2>/dev/null; echo "The submission failed."; exit 1; }
STATUS=$(/usr/bin/plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo "unknown")
if [ "$STATUS" != "Accepted" ]; then
  ID=$(/usr/bin/plutil -extract id raw -o - "$RESULT" 2>/dev/null || echo "")
  echo "Apple did not accept the app (status: $STATUS). Its report:"
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
  exit 1
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# The stapled app is zipped again, so the zip carries the ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Done: $ZIP"
