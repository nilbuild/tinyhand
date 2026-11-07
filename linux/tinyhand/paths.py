"""Where TinyHand finds its images, sounds, and user data."""

import os
import sys
from pathlib import Path


def _package_root():
    return Path(__file__).resolve().parent


def asset_dirs():
    """Directories that can hold the hand images and sounds, in search order."""
    dirs = []
    env = os.environ.get("TINYHAND_ASSETS")
    if env:
        dirs.append(Path(env))
    root = _package_root()
    dirs.append(root.parent / "assets")
    dirs.append(root.parent.parent / "assets")
    dirs.append(data_home() / "assets")
    dirs.append(Path("/usr/local/share/tinyhand/assets"))
    dirs.append(Path("/usr/share/tinyhand/assets"))
    return dirs


def find_asset(relative):
    for base in asset_dirs():
        candidate = base / relative
        if candidate.is_file():
            return candidate
    return None


def data_home():
    base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(base) / "tinyhand"


def cache_home():
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "tinyhand"


def config_home():
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base)


def custom_hands_dir():
    return data_home() / "hands"


def launcher_command():
    """The command that starts TinyHand, for autostart and desktop files."""
    exe = Path(sys.argv[0]).resolve()
    if exe.name == "tinyhand":
        return str(exe)
    run_py = _package_root().parent / "run.py"
    if run_py.is_file():
        return f"{sys.executable} {run_py}"
    return f"{sys.executable} -m tinyhand"
