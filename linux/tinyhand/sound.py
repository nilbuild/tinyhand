"""The tap sound."""

import shutil
import subprocess

from PySide6.QtCore import QUrl

from .paths import find_asset
from .prefs import TAP_SOUNDS

try:
    from PySide6.QtMultimedia import QSoundEffect
except ImportError:  # QtMultimedia is optional; we fall back to a command line player.
    QSoundEffect = None


class TapSound:
    def __init__(self, choice="thock"):
        self.enabled = True
        self.choice = choice
        self._effects = {}
        self._player = shutil.which("pw-play") or shutil.which("paplay") or shutil.which("aplay")
        if QSoundEffect is not None:
            for sound_id, _ in TAP_SOUNDS:
                path = find_asset(f"sounds/tap_{sound_id}.wav")
                if path is None:
                    continue
                effect = QSoundEffect()
                effect.setSource(QUrl.fromLocalFile(str(path)))
                effect.setVolume(1.0)
                self._effects[sound_id] = effect

    def load(self, choice):
        self.choice = choice

    def play(self, choice=None):
        if not self.enabled and choice is None:
            return
        sound_id = choice or self.choice
        effect = self._effects.get(sound_id)
        if effect is not None and effect.status() != QSoundEffect.Status.Error:
            effect.play()
            return
        path = find_asset(f"sounds/tap_{sound_id}.wav")
        if path is None or self._player is None:
            return
        try:
            subprocess.Popen([self._player, str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass
