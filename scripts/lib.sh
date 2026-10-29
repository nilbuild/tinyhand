#!/bin/bash
# Shared by build-app.sh and release.sh.

APP_NAME="TinyHand"
BUNDLE_ID="com.kamranahmed.tinyhand"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

# Never swap the binary under a running copy: macOS can then treat that process as
# untrusted, and its Accessibility permission stops working.
quit_running_app() {
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "Quitting the running $APP_NAME first..."
        osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
        sleep 1
        pkill -x "$APP_NAME" || true
        sleep 0.5
    fi
}

# make_bundle <binary> <app path> <build number>
make_bundle() {
    local binary="$1" app="$2" build="$3"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$binary" "$app/Contents/MacOS/$APP_NAME"
    for name in lavender glove sunny plush robot; do
        cp "$ROOT/assets/hand_$name.png" "$app/Contents/Resources/"
    done
    cp "$ROOT/assets/tap.wav" "$ROOT/assets/AppIcon.icns" "$app/Contents/Resources/"
    cp "$ROOT"/assets/menubar_*.png "$app/Contents/Resources/"

    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$build</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>
    <string>© $(date +%Y) Kamran Ahmed</string>
</dict>
</plist>
PLIST
}
