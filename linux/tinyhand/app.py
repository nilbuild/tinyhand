"""The TinyHand daemon: tray icon, D-Bus control, global shortcuts, and the pointer overlays."""

import configparser
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from PySide6.QtCore import QEvent, QObject, QTimer, Slot
from PySide6.QtDBus import QDBusConnection
from PySide6.QtGui import QAction, QIcon
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon, QWidget

from . import APP_NAME, DBUS_INTERFACE, DBUS_PATH, DBUS_SERVICE
from .overlay import Overlay
from .paths import launcher_command
from .prefs import prefs
from .shortcuts import GlobalShortcuts
from .sound import TapSound
from .styles import HandAsset, PointerStyle

TOGGLE_DEFAULT = "Ctrl+Alt+H"
CLEAR_DEFAULT = "Ctrl+Alt+X"


def panel_is_dark(app):
    """Plasma panels follow the Plasma theme, which can differ from the application colours."""
    name = ""
    for exe in ("kreadconfig6", "kreadconfig5"):
        path = shutil.which(exe)
        if path is None:
            continue
        try:
            result = subprocess.run([path, "--file", "plasmarc", "--group", "Theme", "--key", "name"],
                                    capture_output=True, text=True, timeout=3)
            name = result.stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            name = ""
        break
    if name and name != "default":
        bases = [Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")]
        bases += [Path(d) for d in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":")]
        for base in bases:
            colors = base / "plasma" / "desktoptheme" / name / "colors"
            if not colors.is_file():
                continue
            parser = configparser.ConfigParser(interpolation=None, strict=False)
            try:
                parser.read(colors, encoding="utf-8")
                r, g, b = (int(v) for v in parser["Colors:Window"]["BackgroundNormal"].split(",")[:3])
                return (0.299 * r + 0.587 * g + 0.114 * b) < 128
            except (KeyError, ValueError, configparser.Error):
                break
        lowered = name.lower()
        if "dark" in lowered:
            return True
        if "light" in lowered:
            return False
    return app.palette().window().color().lightness() < 128


class PointerController(QObject):
    """Owns one overlay per screen while the pointer is on."""

    def __init__(self, app, sound, shortcuts):
        super().__init__()
        self.app = app
        self.sound = sound
        self.shortcuts = shortcuts
        self.overlays = []
        self.active = False
        self.style = prefs().pointer_style
        self.on_active_changed = None
        self.on_sound_changed = None
        self.step_aside_timer = QTimer(self)
        self.step_aside_timer.setSingleShot(True)
        self.step_aside_timer.timeout.connect(self._end_step_aside)
        self.stepping_aside = False
        app.screenAdded.connect(self._screens_changed)
        app.screenRemoved.connect(self._screens_changed)
        app.installEventFilter(self)
        prefs().changed.connect(self._prefs_changed)

    # -- on / off --------------------------------------------------------------

    def toggle(self):
        if self.active:
            self.deactivate()
        else:
            self.activate()

    def activate(self):
        if self.active:
            return
        self.active = True
        self.style = prefs().pointer_style
        self.sound.enabled = prefs().sound_on_for(self.style)
        self.sound.load(prefs().tap_sound)
        self._build_overlays()
        reveal_until = time.monotonic() + 3
        first_run = not prefs().first_run_hint_shown
        if first_run:
            prefs().set("firstRunHintShown", True)
            parts = [("Click", "to tap"), ("Drag", "to draw")]
            button = prefs().step_aside_button
            if button != "off":
                parts.append((f"{button.capitalize()}-click", "to click through"))
            parts.append(("Esc", "to exit"))
            reveal_until = time.monotonic() + 10
            for overlay in self.overlays:
                overlay.show_hint(parts, 10)
        for overlay in self.overlays:
            overlay.reveal_for(reveal_until - time.monotonic())
        self.shortcuts.set_active("exit", True)
        if self.on_active_changed:
            self.on_active_changed()

    def deactivate(self):
        if not self.active:
            return
        self.active = False
        self.step_aside_timer.stop()
        self.stepping_aside = False
        self.shortcuts.set_active("exit", False)
        self._destroy_overlays()
        if self.on_active_changed:
            self.on_active_changed()

    def exit(self):
        self.clear_ink()
        self.deactivate()

    def _build_overlays(self):
        self._destroy_overlays()
        for screen in self.app.screens():
            overlay = Overlay(self, screen)
            overlay.set_style(self.style)
            overlay.show()
            self.overlays.append(overlay)

    def _destroy_overlays(self):
        for overlay in self.overlays:
            overlay.hide()
            overlay.deleteLater()
        self.overlays = []

    def _screens_changed(self, screen):
        if self.active:
            QTimer.singleShot(300, self._rebuild_if_active)

    def _rebuild_if_active(self):
        if self.active:
            self._build_overlays()

    # -- events from overlays --------------------------------------------------

    def pointer_entered(self, overlay):
        for other in self.overlays:
            if other is not overlay:
                other.set_hand_hidden(True)

    def tapped(self, overlay):
        self.sound.play()

    def pick(self, style):
        self.style = style
        prefs().pointer_style = style

    def clear_ink(self):
        for overlay in self.overlays:
            overlay.clear_ink()

    @property
    def sound_on(self):
        return prefs().sound_on_for(self.style)

    def toggle_sound(self):
        prefs().set_sound_on_for(self.style, not self.sound_on)

    def step_aside(self):
        """Hide the hand and let clicks through for a few seconds."""
        if not self.active:
            return
        self.stepping_aside = True
        for overlay in self.overlays:
            overlay.set_pass_through(True)
        self.step_aside_timer.start(int(prefs().step_aside_seconds * 1000))

    def _end_step_aside(self):
        self.stepping_aside = False
        for overlay in self.overlays:
            overlay.set_pass_through(False)

    def _prefs_changed(self):
        self.sound.load(prefs().tap_sound)
        style = prefs().pointer_style
        if style != self.style:
            self.style = style
            for overlay in self.overlays:
                overlay.set_style(style)
        self.sound.enabled = prefs().sound_on_for(self.style)
        for overlay in self.overlays:
            overlay.apply_prefs()
        if self.on_sound_changed:
            self.on_sound_changed()

    def eventFilter(self, obj, event):
        # Mouse moves over toolbar buttons still steer the hand.
        if event.type() == QEvent.MouseMove and isinstance(obj, QWidget):
            window = obj.window()
            if isinstance(window, Overlay) and obj is not window:
                window.aim(obj.mapTo(window, event.position().toPoint()))
        return False


class DBusService(QObject):
    """app.tinyhand.TinyHand on the session bus. Slots are the public methods."""

    def __init__(self, daemon):
        super().__init__()
        self.daemon = daemon

    @Slot()
    def Toggle(self):
        self.daemon.pointer.toggle()

    @Slot()
    def TurnOn(self):
        self.daemon.pointer.activate()

    @Slot()
    def TurnOff(self):
        self.daemon.pointer.exit()

    @Slot()
    def Clear(self):
        self.daemon.pointer.clear_ink()

    @Slot()
    def Settings(self):
        self.daemon.open_settings()

    @Slot()
    def Reload(self):
        prefs().reload()

    @Slot()
    def Quit(self):
        self.daemon.quit()

    @Slot(result=bool)
    def IsActive(self):
        return self.daemon.pointer.active


class Daemon(QObject):
    def __init__(self, app):
        super().__init__()
        self.app = app
        app.setQuitOnLastWindowClosed(False)
        app.setApplicationName("tinyhand")
        app.setDesktopFileName("tinyhand")
        self.sound = TapSound(prefs().tap_sound)
        self.shortcuts = GlobalShortcuts(self)
        self.pointer = PointerController(app, self.sound, self.shortcuts)
        self.pointer.on_active_changed = self._refresh_tray
        self.pointer.on_sound_changed = self._refresh_menu
        self.settings_process = None

        self.service = DBusService(self)
        bus = QDBusConnection.sessionBus()
        bus.registerObject(DBUS_PATH, DBUS_INTERFACE, self.service, QDBusConnection.ExportAllSlots)

        self.shortcuts.register("toggle", "Turn pointer on or off", TOGGLE_DEFAULT, self.pointer.toggle)
        self.shortcuts.register("clear", "Clear the drawing", CLEAR_DEFAULT, self.pointer.clear_ink)
        self.shortcuts.register("exit", "Turn pointer off (while it is on)", "Esc", self.pointer.exit, active=False)

        self._setup_tray()
        app.installEventFilter(self)
        QTimer.singleShot(0, self._warm)

    def eventFilter(self, obj, event):
        if event.type() == QEvent.ApplicationPaletteChange and obj is self.app:
            self._refresh_tray()
        return False

    def _warm(self):
        for style in prefs().pinned_styles:
            if not style.is_laser:
                HandAsset.thumbnail(style)

    # -- tray ----------------------------------------------------------------

    def _setup_tray(self):
        self.tray = QSystemTrayIcon(self)
        self.menu = QMenu()
        self.toggle_action = QAction("", self.menu)
        self.toggle_action.triggered.connect(self.pointer.toggle)
        self.clear_action = QAction("", self.menu)
        self.clear_action.triggered.connect(self.pointer.clear_ink)
        self.sound_action = QAction("Tap Sound", self.menu)
        self.sound_action.setCheckable(True)
        self.sound_action.triggered.connect(self.pointer.toggle_sound)
        self.menu.addAction(self.toggle_action)
        self.menu.addAction(self.clear_action)
        self.menu.addAction(self.sound_action)
        self.menu.addSeparator()
        settings_action = QAction("Settings…", self.menu)
        settings_action.triggered.connect(self.open_settings)
        self.menu.addAction(settings_action)
        self.menu.addSeparator()
        quit_action = QAction(f"Quit {APP_NAME}", self.menu)
        quit_action.triggered.connect(self.quit)
        self.menu.addAction(quit_action)
        self.menu.aboutToShow.connect(self._refresh_menu)
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self._tray_activated)
        self._refresh_tray()
        self._refresh_menu()
        self.tray.show()

    def _tray_icon(self, on):
        """Light or dark glyph to match the panel. Plasma shows the pixmap as is, so we pick the colour."""
        name = "tinyhand-tray-on" if on else "tinyhand-tray"
        variant = "light" if panel_is_dark(self.app) else "dark"
        path = Path(__file__).resolve().parent.parent / "data" / "icons" / f"{name}-{variant}.svg"
        if path.is_file():
            return QIcon(str(path))
        return QIcon.fromTheme("input-mouse")

    def _refresh_tray(self):
        on = self.pointer.active
        self.tray.setIcon(self._tray_icon(on))
        self.tray.setToolTip(f"{APP_NAME} is on. Click to turn off, right-click for the menu" if on
                             else f"{APP_NAME}. Click to turn on, right-click for the menu")
        self._refresh_menu()

    def _refresh_menu(self):
        on = self.pointer.active
        toggle_keys = self.shortcuts.current_keys("toggle") or TOGGLE_DEFAULT
        clear_keys = self.shortcuts.current_keys("clear") or CLEAR_DEFAULT
        self.toggle_action.setText(f"{'Turn Pointer Off' if on else 'Turn Pointer On'}\t{toggle_keys}")
        self.clear_action.setText(f"Clear Drawing\t{clear_keys}")
        self.sound_action.setChecked(self.pointer.sound_on)

    def _tray_activated(self, reason):
        if reason in (QSystemTrayIcon.Trigger, QSystemTrayIcon.DoubleClick):
            self.pointer.toggle()
        elif reason == QSystemTrayIcon.MiddleClick:
            self.pointer.clear_ink()

    # -- settings --------------------------------------------------------------

    def open_settings(self):
        """The settings window runs in its own process so it gets a normal window, not a layer surface."""
        self.pointer.exit()
        if self.settings_process is not None and self.settings_process.poll() is None:
            return
        env = dict(os.environ)
        env.pop("QT_WAYLAND_SHELL_INTEGRATION", None)
        command = launcher_command().split(" ", 1)
        if len(command) == 2:
            args = [command[0], command[1], "--settings"]
        else:
            args = [command[0], "--settings"]
        try:
            self.settings_process = subprocess.Popen(args, env=env)
        except OSError as error:
            print(f"could not open settings: {error}", file=sys.stderr)

    def quit(self):
        self.pointer.deactivate()
        self.tray.hide()
        self.app.quit()


def run_daemon(argv):
    os.environ.setdefault("QT_WAYLAND_SHELL_INTEGRATION", "layer-shell")
    app = QApplication(argv)
    bus = QDBusConnection.sessionBus()
    if not bus.registerService(DBUS_SERVICE):
        print(f"{APP_NAME} is already running.", file=sys.stderr)
        return 0
    daemon = Daemon(app)
    if os.environ.pop("TINYHAND_START_ON", ""):
        QTimer.singleShot(0, daemon.pointer.activate)
    return app.exec()
