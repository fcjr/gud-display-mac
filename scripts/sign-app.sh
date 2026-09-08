#!/bin/sh
# Re-sign the built app for notarization.
#   usage: sign-app.sh <path/to/GUD Display.app>
# Set CODESIGN_IDENTITY to a certificate hash if the name is ambiguous locally.
#
# Xcode signs the app and the Sparkle framework bundle but leaves the
# framework's nested executables (Autoupdate, Updater.app, the XPC services)
# with Sparkle's ad-hoc signatures, which the notary service rejects. Sign
# them inside-out with the Developer ID, then re-seal the framework and app.
set -eu

app="$1"
identity="${CODESIGN_IDENTITY:-Developer ID Application: Left Shift Logical, LLC (KNBPD99JQM)}"
entitlements="$(dirname "$0")/../Signing/GUDDisplay.entitlements"
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"

sign() {
    codesign --force --options runtime --timestamp --sign "$identity" "$@"
}

sign "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/XPCServices/Installer.xpc"
sign "$sparkle/Updater.app"
sign "$sparkle/Autoupdate"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$entitlements" "$app"

codesign --verify --deep --strict --verbose=2 "$app"
