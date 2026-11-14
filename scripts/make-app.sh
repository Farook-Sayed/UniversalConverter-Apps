#!/bin/bash
# Builds "Universal Converter.app" with Xcode, so App Intents (Shortcuts and Siri) are registered.
# The Xcode project is generated from project.yml by XcodeGen.
# The app is signed ad hoc, which is enough to run it on this Mac.
set -euo pipefail

cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
mkdir -p build
if ! xcodebuild -project "Universal Converter.xcodeproj" -scheme "Universal Converter" \
        -configuration Release -derivedDataPath build/xcode CODE_SIGN_IDENTITY="-" build \
        >build/xcodebuild.log 2>&1; then
    grep -E "error:" build/xcodebuild.log | tail -20
    echo "The build failed. The full log is in build/xcodebuild.log"
    exit 1
fi

APP="build/Universal Converter.app"
rm -rf "$APP"
cp -R "build/xcode/Build/Products/Release/Universal Converter.app" "$APP"
# --options runtime keeps the hardened runtime that notarization needs (see scripts/sign-and-notarize.sh).
codesign --force --deep --options runtime --sign - "$APP"
echo "Built: $APP"
