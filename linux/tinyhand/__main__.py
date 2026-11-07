"""Command line entry point.

  tinyhand               start the tray app (or do nothing if it already runs)
  tinyhand --toggle      turn the pointer on or off
  tinyhand --on / --off  turn it on or off
  tinyhand --clear       clear the drawing
  tinyhand --settings    open the settings window
  tinyhand --quit        stop the tray app
"""

import os
import sys

from . import APP_NAME, DBUS_INTERFACE, DBUS_PATH, DBUS_SERVICE

_PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))
VERSION_FILES = [
    os.path.join(os.path.dirname(_PACKAGE_DIR), "VERSION"),
    os.path.join(os.path.dirname(os.path.dirname(_PACKAGE_DIR)), "VERSION"),
]

COMMANDS = {
    "--toggle": "Toggle",
    "--on": "TurnOn",
    "--off": "TurnOff",
    "--clear": "Clear",
    "--quit": "Quit",
    "--reload": "Reload",
}


def version():
    for path in VERSION_FILES:
        try:
            with open(path, encoding="utf-8") as handle:
                return handle.read().strip()
        except OSError:
            continue
    return "dev"


def send(method):
    """Call the running daemon. Returns True when a daemon answered."""
    from PySide6.QtCore import QCoreApplication
    from PySide6.QtDBus import QDBusConnection, QDBusInterface, QDBusMessage

    app = QCoreApplication.instance() or QCoreApplication(sys.argv)
    bus = QDBusConnection.sessionBus()
    iface = QDBusInterface(DBUS_SERVICE, DBUS_PATH, DBUS_INTERFACE, bus)
    if not iface.isValid():
        return False
    reply = iface.call(method)
    return reply.type() != QDBusMessage.ErrorMessage


def main(argv=None):
    argv = list(sys.argv if argv is None else argv)
    args = argv[1:]
    if "--help" in args or "-h" in args:
        print(__doc__.strip())
        return 0
    if "--version" in args:
        print(f"{APP_NAME} {version()}")
        return 0
    if "--settings" in args:
        os.environ.pop("QT_WAYLAND_SHELL_INTEGRATION", None)
        from .settings_ui import run_settings

        return run_settings(argv)
    for flag, method in COMMANDS.items():
        if flag in args:
            if send(method):
                return 0
            if flag in ("--toggle", "--on"):
                # Not running yet: start the daemon with the pointer on.
                os.environ["TINYHAND_START_ON"] = "1"
                break
            print(f"{APP_NAME} is not running.", file=sys.stderr)
            return 1
    from .app import run_daemon

    return run_daemon([argv[0]])


if __name__ == "__main__":
    sys.exit(main())
