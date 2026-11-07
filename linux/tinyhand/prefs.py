"""User preferences, stored with QSettings in ~/.config/tinyhand/tinyhand.conf."""

from pathlib import Path

from PySide6.QtCore import QObject, QSettings, Signal

from .paths import config_home, launcher_command
from .styles import DEFAULT_PINNED, RED, LASER, PointerStyle, hex_color

INK_CHOICES = [
    ("match", "Match the pointer", None),
    ("red", "Red", RED),
    ("orange", "Orange", hex_color(0xFF8A00)),
    ("yellow", "Yellow", hex_color(0xFFCC00)),
    ("green", "Green", hex_color(0x30C25A)),
    ("blue", "Blue", hex_color(0x0A84FF)),
    ("purple", "Purple", hex_color(0x8754F2)),
    ("white", "White", hex_color(0xFFFFFF)),
    ("black", "Black", hex_color(0x1D1D21)),
]

TAP_SOUNDS = [
    ("thock", "Thock"),
    ("click", "Click"),
    ("pop", "Pop"),
    ("wood", "Wood block"),
    ("boop", "Boop"),
    ("squeak", "Squeak"),
]

STEP_ASIDE_BUTTONS = [
    ("right", "Right mouse button"),
    ("middle", "Middle mouse button"),
    ("off", "Off"),
]

POINTER_SIZE_MIN = 0.08
POINTER_SIZE_MAX = 0.20
POINTER_SIZE_DEFAULT = 0.13

DEFAULTS = {
    "pointerStyle": "lavender",
    "pointerSize": POINTER_SIZE_DEFAULT,
    "showShadow": True,
    "fadeSeconds": 3.0,
    "sound.hands": True,
    "sound.laser": False,
    "tapSound": "thock",
    "inkChoice": "match",
    "showInkButton": True,
    "pinnedStyles": list(DEFAULT_PINNED),
    "stepAsideButton": "right",
    "stepAsideSeconds": 3.0,
    "firstRunHintShown": False,
}


def ink_color_for(choice_id, style):
    for cid, _, color in INK_CHOICES:
        if cid == choice_id and color is not None:
            return color
    return style.ink_color


class Prefs(QObject):
    """Typed access to the settings. `changed` fires after every write and after reload()."""

    changed = Signal()

    def __init__(self):
        super().__init__()
        self._settings = QSettings(QSettings.IniFormat, QSettings.UserScope, "tinyhand", "tinyhand")

    @property
    def file_path(self):
        return self._settings.fileName()

    def reload(self):
        self._settings.sync()
        self.changed.emit()

    def _get(self, key, kind):
        value = self._settings.value(key, DEFAULTS[key])
        if kind is bool:
            if isinstance(value, str):
                return value.lower() in ("true", "1", "yes")
            return bool(value)
        if kind is float:
            try:
                return float(value)
            except (TypeError, ValueError):
                return float(DEFAULTS[key])
        if kind is list:
            if isinstance(value, str):
                return [value] if value else []
            return list(value) if value else []
        return str(value)

    def set(self, key, value):
        self._settings.setValue(key, value)
        self._settings.sync()
        self.changed.emit()

    def reset_all(self):
        for key in DEFAULTS:
            self._settings.remove(key)
        self._settings.sync()
        self.changed.emit()

    @property
    def pointer_style(self):
        return PointerStyle.from_id(self._get("pointerStyle", str))

    @pointer_style.setter
    def pointer_style(self, style):
        self.set("pointerStyle", style.id)

    @property
    def pointer_size(self):
        return min(POINTER_SIZE_MAX, max(POINTER_SIZE_MIN, self._get("pointerSize", float)))

    @property
    def show_shadow(self):
        return self._get("showShadow", bool)

    @property
    def fade_seconds(self):
        return self._get("fadeSeconds", float)

    @property
    def hand_sound(self):
        return self._get("sound.hands", bool)

    @property
    def laser_sound(self):
        return self._get("sound.laser", bool)

    @property
    def tap_sound(self):
        value = self._get("tapSound", str)
        return value if value in {sid for sid, _ in TAP_SOUNDS} else "thock"

    @property
    def ink_choice(self):
        value = self._get("inkChoice", str)
        return value if value in {cid for cid, _, _ in INK_CHOICES} else "match"

    @property
    def show_ink_button(self):
        return self._get("showInkButton", bool)

    @property
    def pinned_styles(self):
        known = {s.id for s in PointerStyle.all_styles()}
        seen = []
        for raw in self._get("pinnedStyles", list):
            if raw in known and raw not in seen:
                seen.append(raw)
        if not seen:
            seen = list(DEFAULT_PINNED)
        return [PointerStyle(s) for s in seen]

    @property
    def step_aside_button(self):
        value = self._get("stepAsideButton", str)
        return value if value in {bid for bid, _ in STEP_ASIDE_BUTTONS} else "right"

    @property
    def step_aside_seconds(self):
        return max(0.5, self._get("stepAsideSeconds", float))

    @property
    def first_run_hint_shown(self):
        return self._get("firstRunHintShown", bool)

    def sound_on_for(self, style):
        return self.laser_sound if style.is_laser else self.hand_sound

    def set_sound_on_for(self, style, value):
        self.set("sound.laser" if style.is_laser else "sound.hands", bool(value))

    # Launch at login is a desktop file in ~/.config/autostart, not a setting.

    @property
    def autostart_file(self):
        return config_home() / "autostart" / "tinyhand.desktop"

    @property
    def launch_at_login(self):
        return self.autostart_file.is_file()

    @launch_at_login.setter
    def launch_at_login(self, value):
        path = self.autostart_file
        if value:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=TinyHand\n"
                "Comment=A tiny hand on a stick that points at things on your screen\n"
                f"Exec={launcher_command()}\n"
                "Icon=tinyhand\n"
                "Terminal=false\n"
                "X-KDE-autostart-after=panel\n"
                "OnlyShowIn=KDE;\n"
            )
        else:
            path.unlink(missing_ok=True)
        self.changed.emit()


_instance = None


def prefs():
    global _instance
    if _instance is None:
        _instance = Prefs()
    return _instance
