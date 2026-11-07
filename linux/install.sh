#!/bin/sh
# Install TinyHand for the current user (default) or system wide with PREFIX=/usr/local.
#   sh linux/install.sh            install to ~/.local
#   sh linux/install.sh --uninstall
set -eu

PREFIX="${PREFIX:-$HOME/.local}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP_DIR="$PREFIX/share/tinyhand"
BIN="$PREFIX/bin/tinyhand"
DESKTOP="$PREFIX/share/applications/tinyhand.desktop"
ICONS="$PREFIX/share/icons/hicolor"

if [ "${1:-}" = "--uninstall" ]; then
    rm -rf "$APP_DIR"
    rm -f "$BIN" "$DESKTOP" "$HOME/.config/autostart/tinyhand.desktop"
    rm -f "$ICONS/512x512/apps/tinyhand.png"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$PREFIX/share/applications" || true
    echo "TinyHand removed from $PREFIX. Settings stay in ~/.config/tinyhand."
    exit 0
fi

if ! python3 -c "import PySide6.QtWidgets, PySide6.QtDBus, numpy" 2>/dev/null; then
    echo "TinyHand needs python3 with PySide6 and numpy." >&2
    echo "  Fedora:        sudo dnf install python3-pyside6 python3-numpy" >&2
    echo "  Debian/Ubuntu: sudo apt install python3-pyside6.qtwidgets python3-pyside6.qtdbus python3-pyside6.qtmultimedia python3-numpy" >&2
    echo "  Arch:          sudo pacman -S pyside6 python-numpy" >&2
    exit 1
fi
have_layer_shell=0
for lib in /usr/lib*/libLayerShellQtInterface.so.6 /usr/lib/*/libLayerShellQtInterface.so.6; do
    [ -e "$lib" ] && have_layer_shell=1
done
if [ "$have_layer_shell" = 0 ]; then
    echo "Warning: layer-shell-qt was not found. On Wayland the hand will not sit above the panel." >&2
    echo "  Fedora: sudo dnf install layer-shell-qt   Debian/Ubuntu: sudo apt install liblayershellqtinterface6" >&2
fi

mkdir -p "$APP_DIR/assets/sounds" "$PREFIX/bin" "$PREFIX/share/applications" "$ICONS/512x512/apps"
rm -rf "$APP_DIR/tinyhand"
cp -r "$HERE/tinyhand" "$APP_DIR/tinyhand"
rm -rf "$APP_DIR/tinyhand/__pycache__"
cp "$HERE/run.py" "$APP_DIR/run.py"
cp "$ROOT/VERSION" "$APP_DIR/VERSION" 2>/dev/null || true
cp "$ROOT"/assets/hand_*.png "$APP_DIR/assets/"
cp "$ROOT"/assets/sounds/tap_*.wav "$APP_DIR/assets/sounds/"
mkdir -p "$APP_DIR/data/icons"
cp "$HERE"/data/icons/*.svg "$HERE"/data/icons/*.png "$APP_DIR/data/icons/"

cat > "$BIN" <<LAUNCHER
#!/bin/sh
exec python3 "$APP_DIR/run.py" "\$@"
LAUNCHER
chmod +x "$BIN"

sed "s|^Exec=tinyhand|Exec=$BIN|" "$HERE/data/tinyhand.desktop" > "$DESKTOP"
cp "$HERE/data/icons/tinyhand.png" "$ICONS/512x512/apps/tinyhand.png"

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$PREFIX/share/applications" || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$ICONS" 2>/dev/null || true

echo "Installed TinyHand to $PREFIX."
case ":$PATH:" in
    *":$PREFIX/bin:"*) echo "Start it with: tinyhand" ;;
    *) echo "Start it with: $BIN   ($PREFIX/bin is not in your PATH)" ;;
esac
echo "Shortcuts: Ctrl+Alt+H turns the pointer on or off, Ctrl+Alt+X clears the drawing."
