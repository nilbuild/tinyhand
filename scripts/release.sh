#!/bin/bash
# Release build: a universal (Apple silicon + Intel) TinyHand.app, signed with
# Developer ID, notarized and stapled, inside a signed, notarized DMG.
#
#   ./scripts/release.sh                # version from ./VERSION
#   ./scripts/release.sh --skip-notarize
#
# Notarization uses the "notarytool-profile" keychain profile. Create it once with:
#   xcrun notarytool store-credentials notarytool-profile \
#     --apple-id <apple id> --team-id 6QG84AK9XP
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Kamran Ahmed (6QG84AK9XP)}"
PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
SKIP_NOTARIZE=false
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=true

OUT="dist/release"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m
    xcrun stapler staple "$2"
    xcrun stapler validate "$2"
}

echo "==> Building $APP_NAME $VERSION (universal)"
swift build -c release --arch arm64 --arch x86_64
rm -rf "$OUT"
mkdir -p "$OUT"
make_bundle .build/apple/Products/Release/$APP_NAME "$APP" "$BUILD_NUMBER"
lipo -info "$APP/Contents/MacOS/$APP_NAME"

echo "==> Signing with $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo "==> Notarizing the app"
    ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"
    notarize "$OUT/$APP_NAME.zip" "$APP"
    rm "$OUT/$APP_NAME.zip"
fi

echo "==> Building the DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
create-dmg \
    --volname "$APP_NAME" \
    --volicon "assets/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 560 360 \
    --icon-size 112 \
    --icon "$APP_NAME.app" 150 170 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 410 170 \
    --no-internet-enable \
    "$DMG" "$STAGE" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo "==> Notarizing the DMG"
    notarize "$DMG" "$DMG"
    echo "==> Gatekeeper check"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    spctl --assess --type execute --verbose=2 "$APP"
fi

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo
echo "Done: $DMG"
cat "$DMG.sha256"
