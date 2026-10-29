#!/bin/bash
# Release build: a universal (Apple silicon + Intel) TinyHand.app, signed with
# Developer ID, notarized and stapled, inside a signed, notarized DMG.
#
#   ./scripts/release.sh                # version from ./VERSION
#   ./scripts/release.sh --skip-notarize
#
# Notarization uses APPLE_ID / APPLE_PASSWORD (app-specific) / APPLE_TEAM_ID when set
# (as in CI), otherwise the "notarytool-profile" keychain profile. Create that once with:
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
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" --wait --timeout 30m
    else
        xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m
    fi
    xcrun stapler staple "$2"
    xcrun stapler validate "$2"
}

echo "==> Building $APP_NAME $VERSION (universal)"
swift build -c release --arch arm64 --arch x86_64
rm -rf "$OUT"
mkdir -p "$OUT"
make_bundle .build/apple/Products/Release/$APP_NAME "$APP" "$BUILD_NUMBER" --with-updates
lipo -info "$APP/Contents/MacOS/$APP_NAME"

echo "==> Signing with $IDENTITY"
sign_app "$APP" "$IDENTITY" --timestamp

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

echo "==> Signing the update and writing appcast.xml"
# Sparkle checks this EdDSA signature before installing an update. The key comes
# from SPARKLE_PRIVATE_KEY (CI) or the login keychain (account "tinyhand").
TOOLS="$(sparkle_tools)"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    ENCLOSURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/sign_update" --ed-key-file - "$DMG")"
else
    ENCLOSURE="$("$TOOLS/sign_update" --account tinyhand "$DMG")"
fi
NOTES_HTML="$(printf '%s' "${RELEASE_NOTES:-TinyHand $VERSION}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | sed -e 's/$/<br>/')"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <item>
      <title>$APP_NAME $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"
                 type="application/octet-stream" $ENCLOSURE />
    </item>
  </channel>
</rss>
XML

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo
echo "Done: $DMG"
cat "$DMG.sha256"
