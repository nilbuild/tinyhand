"""The settings window. Runs as its own process so it gets a normal window."""

import shutil
import subprocess
import sys

from PySide6.QtCore import QSize, Qt
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import (QApplication, QCheckBox, QComboBox, QDoubleSpinBox, QFormLayout, QFrame, QGridLayout,
                               QGroupBox, QHBoxLayout, QLabel, QMessageBox, QPushButton, QScrollArea, QSlider,
                               QToolButton, QVBoxLayout, QWidget)

from . import APP_NAME, DBUS_INTERFACE, DBUS_PATH, DBUS_SERVICE
from .paths import custom_hands_dir
from .prefs import (INK_CHOICES, POINTER_SIZE_MAX, POINTER_SIZE_MIN,
                    STEP_ASIDE_BUTTONS, TAP_SOUNDS, prefs)
from .shortcuts import read_current_keys
from .sound import TapSound
from .styles import MAX_PINNED, HandAsset, PointerStyle
from .toolbar import laser_icon


def notify_daemon(method="Reload"):
    from PySide6.QtDBus import QDBusConnection, QDBusInterface

    iface = QDBusInterface(DBUS_SERVICE, DBUS_PATH, DBUS_INTERFACE, QDBusConnection.sessionBus())
    if iface.isValid():
        iface.call(method)


class HandPicker(QWidget):
    """A grid of every hand. Up to eight can be pinned to the toolbar."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.buttons = {}
        self.updating = False
        self.grid = QGridLayout(self)
        self.grid.setSpacing(4)
        self.rebuild()

    def rebuild(self):
        while self.grid.count():
            item = self.grid.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self.buttons = {}
        styles = PointerStyle.all_styles()
        columns = 8
        for i, style in enumerate(styles):
            button = QToolButton(self)
            button.setCheckable(True)
            button.setAutoRaise(True)
            button.setIconSize(QSize(44, 44))
            button.setFixedSize(56, 56)
            button.setToolTip(style.title)
            pixmap = laser_icon() if style.is_laser else HandAsset.thumbnail(style)
            if pixmap is not None:
                button.setIcon(QIcon(pixmap))
            else:
                button.setText(style.title[:2])
            button.toggled.connect(lambda checked, s=style: self._toggled(s, checked))
            self.buttons[style] = button
            self.grid.addWidget(button, i // columns, i % columns)
        self.refresh()

    def refresh(self):
        self.updating = True
        pinned = prefs().pinned_styles
        for style, button in self.buttons.items():
            button.setChecked(style in pinned)
        self.updating = False

    def _toggled(self, style, checked):
        if self.updating:
            return
        pinned = prefs().pinned_styles
        if checked:
            if style in pinned:
                return
            if len(pinned) >= MAX_PINNED:
                self.updating = True
                self.buttons[style].setChecked(False)
                self.updating = False
                QMessageBox.information(self, APP_NAME, f"The toolbar holds up to {MAX_PINNED} pointers. "
                                        "Unpin one first.")
                return
            pinned.append(style)
        else:
            if len(pinned) <= 1:
                self.updating = True
                self.buttons[style].setChecked(True)
                self.updating = False
                return
            pinned = [s for s in pinned if s != style]
        prefs().set("pinnedStyles", [s.id for s in pinned])
        notify_daemon()


class SettingsWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(f"{APP_NAME} Settings")
        self.setMinimumWidth(560)
        self.sound = TapSound(prefs().tap_sound)
        self.sound.enabled = True
        self.loading = True

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        scroll = QScrollArea(self)
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        outer.addWidget(scroll)
        body = QWidget()
        scroll.setWidget(body)
        layout = QVBoxLayout(body)
        layout.setSpacing(14)
        layout.setContentsMargins(18, 18, 18, 18)

        # Pointer
        pointer = QGroupBox("Pointer")
        form = QFormLayout(pointer)
        self.size_slider = QSlider(Qt.Horizontal)
        self.size_slider.setRange(int(POINTER_SIZE_MIN * 100), int(POINTER_SIZE_MAX * 100))
        self.size_slider.valueChanged.connect(lambda v: self._set("pointerSize", v / 100))
        form.addRow("Size", self.size_slider)
        self.shadow_box = QCheckBox("Draw a shadow under the hand")
        self.shadow_box.toggled.connect(lambda v: self._set("showShadow", v))
        form.addRow("", self.shadow_box)
        self.style_combo = QComboBox()
        for style in PointerStyle.all_styles():
            self.style_combo.addItem(style.title, style.id)
        self.style_combo.currentIndexChanged.connect(
            lambda i: self._set("pointerStyle", self.style_combo.itemData(i)))
        form.addRow("Current pointer", self.style_combo)
        layout.addWidget(pointer)

        pins = QGroupBox(f"Pointers in the toolbar (up to {MAX_PINNED})")
        pins_layout = QVBoxLayout(pins)
        self.picker = HandPicker(pins)
        pins_layout.addWidget(self.picker)
        custom = QLabel(f'Your own hands: put a PNG with a transparent background, the hand on its stick and the '
                        f'fingertip at the top, into <code>{custom_hands_dir()}</code>. The built-in hands in '
                        f'the assets folder show the layout.')
        custom.setWordWrap(True)
        custom.setTextFormat(Qt.RichText)
        pins_layout.addWidget(custom)
        layout.addWidget(pins)

        # Drawing
        drawing = QGroupBox("Drawing")
        form = QFormLayout(drawing)
        self.ink_combo = QComboBox()
        for choice_id, title, _ in INK_CHOICES:
            self.ink_combo.addItem(title, choice_id)
        self.ink_combo.currentIndexChanged.connect(lambda i: self._set("inkChoice", self.ink_combo.itemData(i)))
        form.addRow("Ink colour", self.ink_combo)
        self.fade_spin = QDoubleSpinBox()
        self.fade_spin.setRange(0, 60)
        self.fade_spin.setDecimals(1)
        self.fade_spin.setSingleStep(0.5)
        self.fade_spin.setSuffix(" s")
        self.fade_spin.setSpecialValueText("Keep until cleared")
        self.fade_spin.valueChanged.connect(lambda v: self._set("fadeSeconds", v))
        form.addRow("Fade drawing after", self.fade_spin)
        self.ink_button_box = QCheckBox("Show the ink colour button in the toolbar")
        self.ink_button_box.toggled.connect(lambda v: self._set("showInkButton", v))
        form.addRow("", self.ink_button_box)
        layout.addWidget(drawing)

        # Sound
        sound = QGroupBox("Tap sound")
        form = QFormLayout(sound)
        row = QHBoxLayout()
        self.sound_combo = QComboBox()
        for sound_id, title in TAP_SOUNDS:
            self.sound_combo.addItem(title, sound_id)
        self.sound_combo.currentIndexChanged.connect(self._sound_changed)
        row.addWidget(self.sound_combo, 1)
        play = QPushButton("Play")
        play.clicked.connect(lambda: self.sound.play(self.sound_combo.currentData()))
        row.addWidget(play)
        form.addRow("Sound", row)
        self.hand_sound_box = QCheckBox("Play when a hand taps")
        self.hand_sound_box.toggled.connect(lambda v: self._set("sound.hands", v))
        form.addRow("", self.hand_sound_box)
        self.laser_sound_box = QCheckBox("Play when the laser dot taps")
        self.laser_sound_box.toggled.connect(lambda v: self._set("sound.laser", v))
        form.addRow("", self.laser_sound_box)
        layout.addWidget(sound)

        # Clicking through
        through = QGroupBox("Clicking through")
        form = QFormLayout(through)
        self.aside_combo = QComboBox()
        for button_id, title in STEP_ASIDE_BUTTONS:
            self.aside_combo.addItem(title, button_id)
        self.aside_combo.currentIndexChanged.connect(
            lambda i: self._set("stepAsideButton", self.aside_combo.itemData(i)))
        form.addRow("Hand steps aside on", self.aside_combo)
        self.aside_spin = QDoubleSpinBox()
        self.aside_spin.setRange(0.5, 30)
        self.aside_spin.setDecimals(1)
        self.aside_spin.setSingleStep(0.5)
        self.aside_spin.setSuffix(" s")
        self.aside_spin.valueChanged.connect(lambda v: self._set("stepAsideSeconds", v))
        form.addRow("Comes back after", self.aside_spin)
        note = QLabel("While the pointer is on, your clicks tap instead of clicking. Press the step-aside button "
                      "to hide the hand and click the real thing underneath. Wayland does not let an app pass a "
                      "click on, so the hand steps aside for a moment instead.")
        note.setWordWrap(True)
        form.addRow(note)
        layout.addWidget(through)

        # Shortcuts
        keys = QGroupBox("Keyboard shortcuts")
        form = QFormLayout(keys)
        self.toggle_label = QLabel()
        self.clear_label = QLabel()
        form.addRow("Turn pointer on or off", self.toggle_label)
        form.addRow("Clear the drawing", self.clear_label)
        form.addRow("Turn pointer off", QLabel("Esc (while it is on)"))
        change = QPushButton("Change in System Settings…")
        change.clicked.connect(self._open_shortcut_settings)
        form.addRow("", change)
        hint = QLabel(f"The shortcuts are listed under “{APP_NAME}” in System Settings > Keyboard > Shortcuts "
                      f"once {APP_NAME} has run.")
        hint.setWordWrap(True)
        form.addRow(hint)
        layout.addWidget(keys)

        # Startup
        startup = QGroupBox("Startup")
        form = QFormLayout(startup)
        self.login_box = QCheckBox("Open at login")
        self.login_box.toggled.connect(self._login_changed)
        form.addRow("", self.login_box)
        layout.addWidget(startup)

        bottom = QHBoxLayout()
        reset = QPushButton("Reset to defaults")
        reset.clicked.connect(self._reset)
        bottom.addWidget(reset)
        bottom.addStretch(1)
        where = QLabel(f"<small>Settings file: {prefs().file_path}</small>")
        where.setTextInteractionFlags(Qt.TextSelectableByMouse)
        bottom.addWidget(where)
        layout.addLayout(bottom)

        self.load()
        self.resize(640, 820)

    def load(self):
        self.loading = True
        p = prefs()
        self.size_slider.setValue(int(round(p.pointer_size * 100)))
        self.shadow_box.setChecked(p.show_shadow)
        index = self.style_combo.findData(p.pointer_style.id)
        self.style_combo.setCurrentIndex(max(0, index))
        self.ink_combo.setCurrentIndex(max(0, self.ink_combo.findData(p.ink_choice)))
        self.fade_spin.setValue(p.fade_seconds)
        self.ink_button_box.setChecked(p.show_ink_button)
        self.sound_combo.setCurrentIndex(max(0, self.sound_combo.findData(p.tap_sound)))
        self.hand_sound_box.setChecked(p.hand_sound)
        self.laser_sound_box.setChecked(p.laser_sound)
        self.aside_combo.setCurrentIndex(max(0, self.aside_combo.findData(p.step_aside_button)))
        self.aside_spin.setValue(p.step_aside_seconds)
        self.login_box.setChecked(p.launch_at_login)
        self.toggle_label.setText(read_current_keys("toggle", "Turn pointer on or off") or "Ctrl+Alt+H")
        self.clear_label.setText(read_current_keys("clear", "Clear the drawing") or "Ctrl+Alt+X")
        self.picker.refresh()
        self.loading = False

    def _set(self, key, value):
        if self.loading:
            return
        prefs().set(key, value)
        notify_daemon()

    def _sound_changed(self, index):
        if self.loading:
            return
        choice = self.sound_combo.itemData(index)
        self._set("tapSound", choice)
        self.sound.play(choice)

    def _login_changed(self, value):
        if self.loading:
            return
        prefs().launch_at_login = value

    def _reset(self):
        prefs().reset_all()
        notify_daemon()
        self.load()

    def _open_shortcut_settings(self):
        exe = shutil.which("systemsettings") or shutil.which("systemsettings5")
        if exe is None:
            QMessageBox.information(self, APP_NAME, "System Settings was not found. Open it from the launcher and "
                                    "look for Keyboard > Shortcuts.")
            return
        subprocess.Popen([exe, "kcm_keys"])


def run_settings(argv):
    app = QApplication(argv)
    app.setApplicationName("tinyhand")
    app.setDesktopFileName("tinyhand")
    icon = QIcon.fromTheme("tinyhand")
    if icon.isNull():
        from pathlib import Path

        icon_path = Path(__file__).resolve().parent.parent / "data" / "icons" / "tinyhand.png"
        if icon_path.is_file():
            icon = QIcon(str(icon_path))
    app.setWindowIcon(icon)
    notify_daemon("TurnOff")
    window = SettingsWindow()
    window.show()
    return app.exec()
