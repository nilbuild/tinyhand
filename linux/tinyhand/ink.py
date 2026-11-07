"""Drawing strokes that fade away."""

import time

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QPainterPath, QPen

FADE_DURATION = 0.6


class Stroke:
    __slots__ = ("points", "base", "color", "width", "ended_at", "bounds")

    def __init__(self, point, color, width):
        self.points = [QPointF(point)]
        self.base = QPainterPath(QPointF(point))
        self.color = QColor(color)
        self.width = width
        self.ended_at = None
        pad = width / 2 + 6
        self.bounds = QRectF(point.x() - pad, point.y() - pad, 2 * pad, 2 * pad)

    def path(self):
        path = QPainterPath(self.base)
        if len(self.points) == 1:
            path.lineTo(self.points[0])
        else:
            path.lineTo(self.points[-1])
        return path

    def extend(self, point):
        prev = self.points[-1]
        mid = QPointF((prev.x() + point.x()) / 2, (prev.y() + point.y()) / 2)
        self.base.quadTo(prev, mid)
        self.points.append(QPointF(point))
        pad = self.width / 2 + 6
        segment = QRectF(prev, point).normalized().adjusted(-pad, -pad, pad, pad)
        self.bounds = self.bounds.united(segment)
        return segment


class Ink:
    def __init__(self):
        self.color = QColor(135, 84, 242)
        self.fade_seconds = 3.0
        self.strokes = []
        self.current = None

    @property
    def keep(self):
        return self.fade_seconds <= 0

    @property
    def fade_delay(self):
        return max(0.5, self.fade_seconds)

    @property
    def is_drawing(self):
        return self.current is not None

    def begin(self, point, width):
        stroke = Stroke(point, self.color, width)
        self.strokes.append(stroke)
        self.current = stroke
        return stroke.bounds

    def extend(self, point):
        if self.current is None:
            return None
        last = self.current.points[-1]
        if (point - last).manhattanLength() < 1.5:
            return None
        return self.current.extend(point)

    def end(self):
        if self.current is None:
            return
        self.current.ended_at = time.monotonic()
        self.current = None

    def clear(self):
        rects = [s.bounds for s in self.strokes]
        self.strokes = []
        self.current = None
        return rects

    def opacity(self, stroke, now):
        if stroke.ended_at is None or self.keep:
            return 1.0
        start = stroke.ended_at + self.fade_delay
        if now < start:
            return 1.0
        return max(0.0, 1.0 - (now - start) / FADE_DURATION)

    def is_fading(self, stroke, now):
        return stroke.ended_at is not None and not self.keep and now >= stroke.ended_at + self.fade_delay

    def has_pending_fade(self):
        return not self.keep and any(s.ended_at is not None for s in self.strokes)

    def prune(self, now):
        """Drop strokes that finished fading. Returns the rects that changed."""
        dirty = []
        remaining = []
        for stroke in self.strokes:
            if self.is_fading(stroke, now):
                dirty.append(stroke.bounds)
            if self.opacity(stroke, now) <= 0:
                continue
            remaining.append(stroke)
        self.strokes = remaining
        return dirty

    def paint(self, painter, clip):
        now = time.monotonic()
        painter.save()
        painter.setRenderHint(painter.RenderHint.Antialiasing)
        painter.setBrush(Qt.NoBrush)
        for stroke in self.strokes:
            if not stroke.bounds.intersects(clip):
                continue
            alpha = self.opacity(stroke, now)
            if alpha <= 0:
                continue
            path = stroke.path()
            painter.setOpacity(alpha)
            shadow = QPen(QColor(0, 0, 0, 46), stroke.width + 1.5, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
            painter.setPen(shadow)
            painter.drawPath(path.translated(1.0, 1.5))
            pen = QPen(stroke.color, stroke.width, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
            painter.setPen(pen)
            painter.drawPath(path)
        painter.restore()
