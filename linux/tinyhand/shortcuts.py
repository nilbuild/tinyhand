"""Global shortcuts through KDE's KGlobalAccel daemon over D-Bus.

The shortcuts show up in System Settings > Keyboard > Shortcuts under "TinyHand",
where the user can change them. We use busctl for the calls whose arguments PySide6
cannot marshal (integer arrays) and QtDBus for the signal.
"""

import shutil
import subprocess

from PySide6.QtCore import QObject, Slot, SLOT
from PySide6.QtDBus import QDBusConnection, QDBusInterface, QDBusMessage
from PySide6.QtGui import QKeySequence

COMPONENT = "tinyhand"
COMPONENT_FRIENDLY = "TinyHand"
SERVICE = "org.kde.kglobalaccel"
PATH = "/kglobalaccel"
INTERFACE = "org.kde.KGlobalAccel"
COMPONENT_INTERFACE = "org.kde.kglobalaccel.Component"

SET_PRESENT = 2
NO_AUTOLOADING = 4
IS_DEFAULT = 8


def _busctl(method, signature="", *args):
    exe = shutil.which("busctl")
    if exe is None:
        return None
    cmd = [exe, "--user", "--timeout=3", "call", SERVICE, PATH, INTERFACE, method]
    if signature:
        cmd.append(signature)
        cmd.extend(str(a) for a in args)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def _parse_int_array(text):
    """busctl prints `ai 2 123 456`; return the integers."""
    if not text:
        return []
    parts = text.split()
    if len(parts) < 2 or parts[0] != "ai":
        return []
    try:
        count = int(parts[1])
        return [int(p) for p in parts[2 : 2 + count]]
    except ValueError:
        return []


class GlobalShortcuts(QObject):
    """Registers named actions with default keys and calls back when one is pressed."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._bus = QDBusConnection.sessionBus()
        self._callbacks = {}
        self._friendly = {}
        self._defaults = {}
        self.available = self._bus.isConnected() and shutil.which("busctl") is not None
        self._listening = False

    def _action_id(self, action):
        return [COMPONENT, action, COMPONENT_FRIENDLY, self._friendly.get(action, action)]

    def register(self, action, friendly, default_keys, callback, active=True):
        """`default_keys` is a key sequence string such as "Ctrl+Alt+H"."""
        self._callbacks[action] = callback
        self._friendly[action] = friendly
        self._defaults[action] = default_keys
        if not self.available:
            return False
        iface = QDBusInterface(SERVICE, PATH, INTERFACE, self._bus)
        iface.call("doRegister", self._action_id(action))
        key = QKeySequence(default_keys)[0].toCombined() if default_keys else 0
        aid = self._action_id(action)
        _busctl("setShortcut", "asaiu", 4, *aid, 1, key, SET_PRESENT | IS_DEFAULT)
        if active:
            _busctl("setShortcut", "asaiu", 4, *aid, 1, key, SET_PRESENT)
        else:
            _busctl("setInactive", "as", 4, *aid)
        self._listen()
        return True

    def set_active(self, action, active):
        if not self.available or action not in self._callbacks:
            return
        aid = self._action_id(action)
        if active:
            key = QKeySequence(self._defaults[action])[0].toCombined() if self._defaults[action] else 0
            _busctl("setShortcut", "asaiu", 4, *aid, 1, key, SET_PRESENT)
        else:
            _busctl("setInactive", "as", 4, *aid)

    def current_keys(self, action):
        """The key sequence the user currently has for an action, as display text."""
        if not self.available:
            return self._defaults.get(action, "")
        text = _busctl("shortcut", "as", 4, *self._action_id(action))
        keys = [k for k in _parse_int_array(text) if k > 0]
        if not keys:
            return ""
        return QKeySequence(keys[0]).toString(QKeySequence.NativeText)

    def _listen(self):
        if self._listening:
            return
        self._listening = self._bus.connect(
            SERVICE, f"/component/{COMPONENT}", COMPONENT_INTERFACE, "globalShortcutPressed",
            self, SLOT("_pressed(QDBusMessage)"),
        )

    @Slot(QDBusMessage)
    def _pressed(self, message):
        args = message.arguments()
        if len(args) < 2 or args[0] != COMPONENT:
            return
        callback = self._callbacks.get(args[1])
        if callback is not None:
            callback()


def read_current_keys(action, friendly_fallback=""):
    """Read a shortcut without registering anything, for the settings window."""
    text = _busctl("shortcut", "as", 4, COMPONENT, action, COMPONENT_FRIENDLY, friendly_fallback or action)
    keys = [k for k in _parse_int_array(text) if k > 0]
    if not keys:
        return ""
    return QKeySequence(keys[0]).toString(QKeySequence.NativeText)
