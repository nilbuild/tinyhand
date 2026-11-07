"""Pointer styles (the 36 hands and the laser dot) and the hand image measurements."""

import colorsys
import json
import os
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PySide6.QtCore import QRect, Qt
from PySide6.QtGui import QColor, QImage, QPixmap

from .paths import cache_home, custom_hands_dir, find_asset

PURPLE = QColor.fromRgbF(0.53, 0.33, 0.95)
RED = QColor.fromRgbF(1.0, 0.16, 0.12)


def hex_color(value):
    return QColor((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)


BUILT_IN = [
    ("lavender", "Lavender toy", PURPLE),
    ("glove", "Cursor glove", PURPLE),
    ("coral", "Coral vinyl", RED),
    ("plush", "Plush", hex_color(0x2F86F0)),
    ("robot", "Robot", hex_color(0x16A87A)),
    ("pink", "Bubblegum", hex_color(0xEE4F98)),
    ("blue", "Sky", hex_color(0x2F86F0)),
    ("mint", "Mint", hex_color(0x16A87A)),
    ("lemon", "Lemon", hex_color(0xF2B705)),
    ("black", "Midnight", hex_color(0x1D1D21)),
    ("chrome", "Chrome", hex_color(0x6B7380)),
    ("holo", "Holo", PURPLE),
    ("fuzzy", "Fuzzy", PURPLE),
    ("wood", "Wood", hex_color(0x9A5E2C)),
    ("marble", "Marble", hex_color(0x6B7380)),
    ("terrazzo", "Terrazzo", hex_color(0xF0561D)),
    ("glass", "Glass", hex_color(0x1597E5)),
    ("jelly", "Jelly", hex_color(0xA33FE6)),
    ("pastel", "Pastel", hex_color(0xEE4F98)),
    ("pixel", "Pixel", hex_color(0x1D1D21)),
    ("lowpoly", "Low poly", PURPLE),
    ("knit", "Knit", PURPLE),
    ("skeleton", "Skeleton", hex_color(0x9A5E2C)),
    ("astro", "Astronaut", hex_color(0x2F86F0)),
    ("space", "Space", RED),
    ("monster", "Monster", hex_color(0x3E9E2E)),
    ("water", "Water", hex_color(0x1597E5)),
    ("lava", "Lava", hex_color(0xF0561D)),
    ("grass", "Grass", hex_color(0x3E9E2E)),
    ("cactus", "Cactus", hex_color(0x3E9E2E)),
    ("choco", "Chocolate", hex_color(0x9A5E2C)),
    ("cloud", "Cloud", hex_color(0x2F86F0)),
    ("mech", "Mech", hex_color(0xF0561D)),
    ("neon", "Neon", hex_color(0xE0309A)),
    ("leaf", "Leaf", hex_color(0x3E9E2E)),
    ("cookie", "Gingerbread", hex_color(0x9A5E2C)),
]

LASER = "laser"
DEFAULT_PINNED = ["lavender", "glove", "coral", "plush", "robot", LASER]
MAX_PINNED = 8


class PointerStyle:
    """One pointer look. Built-in hands are keyed by their short id, custom hands by file name."""

    __slots__ = ("id",)

    def __init__(self, style_id):
        self.id = style_id

    def __eq__(self, other):
        return isinstance(other, PointerStyle) and other.id == self.id

    def __hash__(self):
        return hash(self.id)

    def __repr__(self):
        return f"PointerStyle({self.id!r})"

    @property
    def is_laser(self):
        return self.id == LASER

    @property
    def is_custom(self):
        return self.id.startswith("custom:")

    @property
    def title(self):
        if self.is_laser:
            return "Laser dot"
        if self.is_custom:
            name = self.id[len("custom:"):]
            return name.replace("_", " ").replace("-", " ").strip().capitalize() or name
        for style_id, title, _ in BUILT_IN:
            if style_id == self.id:
                return title
        return self.id

    @property
    def image_path(self):
        if self.is_laser:
            return None
        if self.is_custom:
            path = custom_hands_dir() / (self.id[len("custom:"):] + ".png")
            return path if path.is_file() else None
        return find_asset(f"hand_{self.id}.png")

    @property
    def ink_color(self):
        if self.is_laser:
            return RED
        if self.is_custom:
            asset = HandAsset.load(self)
            return asset.ink if asset is not None and asset.ink is not None else PURPLE
        for style_id, _, color in BUILT_IN:
            if style_id == self.id:
                return color
        return PURPLE

    @staticmethod
    def built_in_hands():
        return [PointerStyle(style_id) for style_id, _, _ in BUILT_IN]

    @staticmethod
    def custom_hands():
        folder = custom_hands_dir()
        if not folder.is_dir():
            return []
        names = sorted(p.stem for p in folder.glob("*.png"))
        return [PointerStyle("custom:" + name) for name in names]

    @staticmethod
    def all_styles():
        return PointerStyle.built_in_hands() + PointerStyle.custom_hands() + [PointerStyle(LASER)]

    @staticmethod
    def from_id(style_id, fallback="lavender"):
        if style_id == "dot":
            style_id = LASER
        if style_id == "sunny":
            style_id = "coral"
        style = PointerStyle(style_id or "")
        if style.is_laser or style.id in {s.id for s in PointerStyle.all_styles()}:
            return style
        return PointerStyle(fallback)


@dataclass
class HandAsset:
    """A hand image and where its parts sit, all as fractions of the image size."""

    image: QImage
    aspect: float
    hand_top: float
    tip: float
    wrist: float
    rod_end: float
    tip_x: float
    rod_x: float
    hand_min_x: float
    hand_max_x: float
    ink: QColor | None

    _cache = {}
    _recent = []
    _cache_limit = 3
    _thumbnails = {}

    @classmethod
    def load(cls, style):
        path = style.image_path
        if path is None:
            return None
        key = str(path)
        hit = cls._cache.get(key)
        if hit is not None:
            cls._touch(key)
            return hit
        image = QImage(str(path))
        if image.isNull():
            return None
        image = image.convertToFormat(QImage.Format_ARGB32_Premultiplied)
        asset = cls.measure(image, want_ink=style.is_custom)
        if asset is None:
            return None
        cls._cache[key] = asset
        cls._touch(key)
        return asset

    @classmethod
    def _touch(cls, key):
        if key in cls._recent:
            cls._recent.remove(key)
        cls._recent.append(key)
        while len(cls._recent) > cls._cache_limit:
            cls._cache.pop(cls._recent.pop(0), None)

    @classmethod
    def forget(cls, style):
        path = style.image_path
        if path is None:
            return
        cls._cache.pop(str(path), None)
        cls._thumbnails.pop(style.id, None)

    @staticmethod
    def measure(image, want_ink=False):
        """Find the fingertip, wrist, and stick in the alpha channel, like the macOS version."""
        w = image.width()
        h = image.height()
        if w < 8 or h < 8:
            return None
        if image.format() != QImage.Format_ARGB32_Premultiplied:
            image = image.convertToFormat(QImage.Format_ARGB32_Premultiplied)
        raw = np.frombuffer(image.constBits(), dtype=np.uint8)
        pixels = raw.reshape(h, image.bytesPerLine())[:, : w * 4].reshape(h, w, 4)
        alpha = pixels[:, :, 3] > 128
        counts = alpha.sum(axis=1)
        rows = np.flatnonzero(counts)
        if len(rows) == 0:
            return None
        top = int(rows[0])
        last = int(rows[-1])
        search_end = min(h, top + int(0.45 * h))
        max_w = int(counts[top:search_end].max())
        if max_w <= 0:
            return None
        fist_rows = np.flatnonzero(counts[top:] > 0.6 * max_w)
        if len(fist_rows) == 0:
            return None
        fist = top + int(fist_rows[0])
        wrist_rows = np.flatnonzero(counts[fist:] < 0.35 * max_w)
        if len(wrist_rows) == 0:
            return None
        wrist = fist + int(wrist_rows[0])
        rod_w = int(counts[min(h - 1, wrist + h // 50)])
        start = min(h - 1, wrist + h // 33)
        handle_rows = np.flatnonzero(counts[start:] > 1.8 * rod_w)
        rod_end = start + int(handle_rows[0]) if len(handle_rows) else last

        def center(y):
            xs = np.flatnonzero(alpha[y])
            if len(xs) == 0:
                return 0.5
            return (int(xs[0]) + int(xs[-1])) / 2 / w

        columns = np.flatnonzero(alpha[top:wrist].any(axis=0))
        min_x = int(columns[0]) if len(columns) else 0
        max_x = int(columns[-1]) if len(columns) else w - 1

        ink = None
        if want_ink:
            ink = HandAsset._dominant_color(pixels[top:wrist])

        fh = float(h)
        return HandAsset(
            image=image,
            aspect=w / fh,
            hand_top=max(0.0, top - 0.004 * fh) / fh,
            tip=top / fh,
            wrist=wrist / fh,
            rod_end=rod_end / fh,
            tip_x=center(min(h - 1, top + h // 200)),
            rod_x=center((wrist + rod_end) // 2),
            hand_min_x=min_x / w,
            hand_max_x=max_x / w,
            ink=ink,
        )

    @staticmethod
    def _dominant_color(pixels):
        """A bright, saturated version of the hand's average colour, for custom hands' ink."""
        solid = pixels[pixels[:, :, 3] > 200]
        if len(solid) == 0:
            return None
        mean = solid[:, :3].astype(np.float64).mean(axis=0) / 255.0
        b, g, r = mean
        hue, sat, val = colorsys.rgb_to_hsv(r, g, b)
        sat = max(sat, 0.6)
        val = max(val, 0.75)
        r, g, b = colorsys.hsv_to_rgb(hue, sat, val)
        return QColor.fromRgbF(r, g, b)

    @classmethod
    def thumbnail(cls, style, size=64):
        """A square crop of just the hand, cached in memory and on disk."""
        key = (style.id, size)
        hit = cls._thumbnails.get(key)
        if hit is not None:
            return hit
        path = style.image_path
        if path is None:
            return None
        cache_dir = cache_home() / "thumbs"
        stamp = f"{path.stat().st_mtime_ns}-{path.stat().st_size}-{size}"
        safe = style.id.replace(":", "_").replace("/", "_")
        cache_file = cache_dir / f"{safe}-{stamp}.png"
        if cache_file.is_file():
            pix = QPixmap(str(cache_file))
            if not pix.isNull():
                cls._thumbnails[key] = pix
                return pix
        asset = cls.load(style)
        if asset is None:
            return None
        image = asset.image
        w = image.width()
        h = image.height()
        hand_w = (asset.hand_max_x - asset.hand_min_x) * w
        hand_h = (asset.wrist - asset.hand_top) * h
        side = max(hand_w, hand_h) * 1.06
        cx = (asset.hand_min_x + asset.hand_max_x) / 2 * w
        cy = (asset.hand_top + asset.wrist) / 2 * h
        rect = QRect(int(cx - side / 2), int(cy - side / 2), int(side), int(side)).intersected(QRect(0, 0, w, h))
        px = size * 2
        small = image.copy(rect).scaled(px, px, Qt.KeepAspectRatio, Qt.SmoothTransformation)
        small.setDevicePixelRatio(2.0)
        pix = QPixmap.fromImage(small)
        try:
            cache_dir.mkdir(parents=True, exist_ok=True)
            for old in cache_dir.glob(f"{safe}-*.png"):
                old.unlink(missing_ok=True)
            small.save(str(cache_file))
        except OSError:
            pass
        cls._thumbnails[key] = pix
        return pix
