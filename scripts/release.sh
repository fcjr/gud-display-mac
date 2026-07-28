#!/bin/bash
# Release build: generate, build, notarize, staple, zip.
#
# One-time setup:
#   xcrun notarytool store-credentials gudmac-notary \
#     --apple-id <apple-id> --team-id KNBPD99JQM --password <app-specific-password>
#
# Sparkle: after building, sign the zip for the appcast with the project key
# (keys/sparkle_ed25519_key, gitignored; also in the login keychain under
# account "gudmac"):
#   ./build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
#     -f keys/sparkle_ed25519_key <zip>
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-gudmac-notary}"
VERSION="${1:?usage: release.sh <version>}"
BUILD_DIR=build
APP="$BUILD_DIR/Build/Products/Release/gudmac.app"
ZIP="$BUILD_DIR/gudmac-$VERSION.zip"

xcodegen generate
xcodebuild -project gudmac.xcodeproj -scheme gudmac -configuration Release \
    -derivedDataPath "$BUILD_DIR" clean build

codesign --verify --deep --strict "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

# Re-zip with the stapled ticket for distribution.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Release artifact: $ZIP"
echo "Next: sign_update for the Sparkle appcast, upload zip + appcast.xml."
