#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DESTINATION="$PWD/ASCII Webcam.app"
# Build/sign outside cloud-synced Documents: File Provider can attach FinderInfo
# between metadata cleanup and codesign, causing intermittent signing failures.
STAGING="$(mktemp -d /private/tmp/ascii-webcam-build.XXXXXX)"
APP="$STAGING/ASCII Webcam.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/build/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -module-cache-path "$PWD/build/module-cache" \
  macos/ASCIIWebcam.swift -o "$APP/Contents/MacOS/ASCII Webcam" \
  -framework AppKit -framework AVFoundation -framework CoreText
cp macos/Info.plist "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/ASCII Webcam" --make-icon "$PWD/build/AppIcon.iconset"
iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Finder/cloud folders can attach metadata that codesign rejects.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
ditto --norsrc --noextattr "$APP" "$DESTINATION"
xattr -dr com.apple.FinderInfo "$DESTINATION" 2>/dev/null || true
echo "Built: $DESTINATION"
