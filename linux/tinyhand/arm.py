"""The hand on a stick: where it is, how it leans, and how it is drawn."""

import math

import numpy as np
from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QImage, QPainter, QRadialGradient, QTransform

from .styles import RED, HandAsset, PointerStyle


class ArmRenderer:
    GRIP_LEAN = 0.30
    GRIP_DEPTH = 0.12
    GRIP_FOLLOW = 0.08
    LIFT = 0.06
    MIN_ROD = 0.05

    def __init__(self):
        self.style = PointerStyle("lavender")
        self.asset = None
        self.hand_len_frac = 0.13
        self.show_shadow = True
        self.hidden = False
        self.held = False
        self.press_amount = 0.0
        self.grip_x = None
        self.grip_target = None
        self.cursor = None
        self.width = 0
        self.height = 0
        self.dpr = 1.0
        self.pose = None
        self._display = None
        self._shadow = None
        self._display_height = 0

    # -- state ---------------------------------------------------------------

    @property
    def is_settling(self):
        if self.press_amount > 0.002:
            return True
        if self.grip_x is None or self.grip_target is None:
            return False
        return abs(self.grip_target - self.grip_x) > 0.5

    def set_style(self, style):
        self.style = style
        self.asset = None if style.is_laser else HandAsset.load(style)
        if not style.is_laser and self.asset is None:
            self.style = PointerStyle("laser")
        self._display = None
        self._shadow = None
        self._display_height = 0
        self.pose = None

    def set_size(self, width, height, dpr):
        if (width, height, dpr) != (self.width, self.height, self.dpr):
            self.width = width
            self.height = height
            self.dpr = dpr
            self._display_height = 0
            self.pose = None

    def press(self):
        self.press_amount = 1.0

    def bounds(self):
        """Screen rect that the current pose covers, for partial repaints."""
        pose = self.pose
        if pose is None:
            return QRectF()
        if pose["kind"] == "laser":
            r = pose["glow"] + 2
            c = pose["cursor"]
            return QRectF(c.x() - r, c.y() - r, 2 * r, 2 * r)
        width = pose["width"]
        local = QRectF(-pose["rod_x"] * width, -(pose["rod_len"] + pose["hand"]), width, pose["rod_len"] + pose["hand"])
        rect = pose["transform"].mapRect(local)
        shadow = pose["shadow_transform"].mapRect(local)
        margin = pose["lift"] * 0.5 + 12
        return rect.united(shadow).adjusted(-margin, -margin, margin, margin)

    # -- aiming --------------------------------------------------------------

    def aim(self, cursor):
        """Point at `cursor` (overlay coordinates, y down). Returns True when the pose changed."""
        self.cursor = QPointF(cursor)
        w = self.width
        h = self.height
        if w <= 0 or h <= 0:
            return False
        target_x = min(max(cursor.x() + self.GRIP_LEAN * w, w * 0.15), w * 1.05)
        if self.grip_x is None:
            gx = target_x
        else:
            gx = self.grip_x + (target_x - self.grip_x) * self.GRIP_FOLLOW
        self.grip_x = gx
        self.grip_target = target_x
        if not self.held:
            self.press_amount += (0 - self.press_amount) * 0.18
            if self.press_amount < 0.001:
                self.press_amount = 0.0

        if self.style.is_laser or self.asset is None:
            return self._aim_laser(cursor)

        a = self.asset
        self._update_display(a)
        grip_up = QPointF(gx, -self.GRIP_DEPTH * h)
        cursor_up = QPointF(cursor.x(), h - cursor.y())
        dx = cursor_up.x() - grip_up.x()
        dy = cursor_up.y() - grip_up.y()
        reach = math.hypot(dx, dy)
        aim_angle = math.atan2(dy, dx)

        hand_pts = self.hand_len_frac * h * (1 - 0.06 * self.press_amount)
        s = hand_pts / (a.wrist - a.hand_top)
        width_pts = s * a.aspect
        hand_tip_pts = (a.wrist - a.tip) * s
        tip_off_x = (a.tip_x - a.rod_x) * width_pts

        along = math.sqrt(max(0.0, reach * reach - tip_off_x * tip_off_x))
        rod_len = max(self.MIN_ROD * h, along - hand_tip_pts)
        tip_angle = math.atan2(rod_len + hand_tip_pts, tip_off_x)
        rotation = aim_angle - tip_angle

        lift = self.LIFT * h * (1 - 0.8 * self.press_amount)
        shadow_offset = QPointF(lift * 0.6, lift)
        grip = QPointF(gx, h + self.GRIP_DEPTH * h)
        degrees = -math.degrees(rotation)

        key = tuple(round(v * 100) for v in (rotation, rod_len, hand_pts, width_pts, gx, lift, self.press_amount,
                                             1.0 if self.show_shadow else 0.0))
        if self.pose is not None and self.pose.get("key") == key:
            return False
        transform = QTransform().translate(grip.x(), grip.y()).rotate(degrees)
        shadow_transform = QTransform().translate(grip.x() + shadow_offset.x(), grip.y() + shadow_offset.y()).rotate(degrees)
        self.pose = {
            "kind": "hand",
            "key": key,
            "transform": transform,
            "shadow_transform": shadow_transform,
            "rod_len": rod_len,
            "hand": hand_pts,
            "width": width_pts,
            "rod_x": a.rod_x,
            "lift": lift,
            "press": self.press_amount,
        }
        return True

    def _aim_laser(self, cursor):
        press = self.press_amount
        r = max(4.0, self.height * 0.0038 * self.hand_len_frac / 0.13) * (1 + 0.2 * press)
        key = tuple(round(v * 100) for v in (r, cursor.x(), cursor.y()))
        if self.pose is not None and self.pose.get("key") == key:
            return False
        self.pose = {
            "kind": "laser",
            "key": key,
            "cursor": QPointF(cursor),
            "r": r,
            "core": r * 0.45,
            "glow": r * (2.2 + press) * 1.6,
        }
        return True

    # -- images --------------------------------------------------------------

    def _update_display(self, a):
        full = a.image
        rest_pts = self.hand_len_frac * self.height / (a.wrist - a.hand_top)
        step = 64
        needed = (int(math.ceil(rest_pts * self.dpr)) + step - 1) // step * step
        height = full.height() if needed >= full.height() * 9 // 10 else max(step, needed)
        if height == self._display_height and self._display is not None:
            return
        self._display_height = height
        if height == full.height():
            image = full
        else:
            width = max(1, round(full.width() * height / full.height()))
            image = full.scaled(width, height, Qt.IgnoreAspectRatio, Qt.SmoothTransformation)
        self._display = image
        self._shadow = self._make_shadow(image)

    @staticmethod
    def _make_shadow(image):
        """A soft black silhouette of the hand image."""
        img = image.convertToFormat(QImage.Format_ARGB32_Premultiplied).copy()
        h = img.height()
        w = img.width()
        raw = np.frombuffer(img.bits(), dtype=np.uint8)
        pixels = raw.reshape(h, img.bytesPerLine())[:, : w * 4].reshape(h, w, 4)
        pixels[:, :, 0:3] = 0
        small = img.scaled(max(1, w // 6), max(1, h // 6), Qt.IgnoreAspectRatio, Qt.SmoothTransformation)
        return small.scaled(w, h, Qt.IgnoreAspectRatio, Qt.SmoothTransformation)

    # -- painting ------------------------------------------------------------

    def paint(self, painter):
        if self.hidden or self.pose is None:
            return
        if self.pose["kind"] == "laser":
            self._paint_laser(painter)
            return
        a = self.asset
        if a is None or self._display is None:
            return
        pose = self.pose
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        if self.show_shadow:
            painter.save()
            painter.setTransform(pose["shadow_transform"], True)
            painter.setOpacity(0.26 + 0.02 * pose["press"])
            self._paint_group(painter, self._shadow, a, pose)
            painter.restore()
        painter.setTransform(pose["transform"], True)
        self._paint_group(painter, self._display, a, pose)
        painter.restore()

    @staticmethod
    def _paint_group(painter, image, a, pose):
        iw = image.width()
        ih = image.height()
        width = pose["width"]
        rod_len = pose["rod_len"]
        hand = pose["hand"]
        left = -pose["rod_x"] * width
        rod_source = QRectF(0, a.wrist * ih, iw, (a.rod_end - a.wrist) * ih)
        hand_source = QRectF(0, a.hand_top * ih, iw, (a.wrist - a.hand_top) * ih)
        painter.drawImage(QRectF(left, -rod_len, width, rod_len + 1), image, rod_source)
        painter.drawImage(QRectF(left, -(rod_len + hand), width, hand), image, hand_source)

    def _paint_laser(self, painter):
        pose = self.pose
        c = pose["cursor"]
        r = pose["r"]
        glow = pose["glow"]
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(Qt.NoPen)
        gradient = QRadialGradient(c, glow)
        red = QColor(RED)
        red.setAlphaF(0.55)
        gradient.setColorAt(0.0, red)
        mid = QColor(RED)
        mid.setAlphaF(0.18)
        gradient.setColorAt(0.45, mid)
        clear = QColor(RED)
        clear.setAlphaF(0.0)
        gradient.setColorAt(1.0, clear)
        painter.setBrush(gradient)
        painter.drawEllipse(c, glow, glow)
        painter.setBrush(RED)
        painter.drawEllipse(c, r, r)
        painter.setBrush(QColor.fromRgbF(1, 0.86, 0.82, 0.95))
        painter.drawEllipse(c, pose["core"], pose["core"])
        painter.restore()
