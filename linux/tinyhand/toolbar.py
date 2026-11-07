"""The small toolbar at the bottom of the screen, drawn inside the overlay window."""

import math

from PySide6.QtCore import QEasingCurve, QPointF, QPropertyAnimation, QRect, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QColor, QFont, QLinearGradient, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import QGraphicsOpacityEffect, QHBoxLayout, QLabel, QWidget

from .prefs import INK_CHOICES, ink_color_for, prefs
from .styles import RED, HandAsset

BACKGROUND = QColor(28, 28, 32, 222)
BORDER = QColor(255, 255, 255, 36)


def rounded_panel(painter, rect, radius):
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    path = QPainterPath()
    path.addRoundedRect(QRectF(rect), radius, radius)
    painter.fillPath(path, BACKGROUND)
    painter.setPen(QPen(BORDER, 1))
    painter.setBrush(Qt.NoBrush)
    painter.drawPath(path)


def ink_dot(color, size=64):
    pix = QPixmap(size, size)
    pix.fill(Qt.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    c = QPointF(size / 2, size / 2)
    r = size * 13 / 64
    p.setPen(Qt.NoPen)
    p.setBrush(QColor(0, 0, 0, 90))
    p.drawEllipse(QRectF(c.x() - r - 1.5, c.y() - r - 0.5, 2 * r + 3, 2 * r + 3))
    p.setBrush(color)
    p.drawEllipse(c, r, r)
    p.setBrush(QColor(255, 255, 255, 90))
    p.drawEllipse(QRectF(c.x() - r * 0.55, c.y() - r * 0.65, r * 0.7, r * 0.5))
    p.end()
    return pix


def rainbow_dot(size=64):
    pix = QPixmap(size, size)
    pix.fill(Qt.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    c = QPointF(size / 2, size / 2)
    r = size * 13 / 64
    p.setPen(Qt.NoPen)
    p.setBrush(QColor(0, 0, 0, 90))
    p.drawEllipse(QRectF(c.x() - r - 1.5, c.y() - r - 0.5, 2 * r + 3, 2 * r + 3))
    colors = [QColor(255, 59, 48), QColor(255, 149, 0), QColor(255, 204, 0), QColor(52, 199, 89), QColor(0, 122, 255),
              QColor(175, 82, 222)]
    rect = QRectF(c.x() - r, c.y() - r, 2 * r, 2 * r)
    for i, color in enumerate(colors):
        p.setBrush(color)
        p.drawPie(rect, int((90 - i * 60) * 16), int(-60 * 16))
    p.end()
    return pix


def laser_icon(size=64):
    pix = QPixmap(size, size)
    pix.fill(Qt.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    c = QPointF(size / 2, size / 2)
    p.setPen(Qt.NoPen)
    from PySide6.QtGui import QRadialGradient

    glow = QRadialGradient(c, size * 0.3)
    red = QColor(RED)
    red.setAlphaF(0.55)
    glow.setColorAt(0, red)
    red2 = QColor(RED)
    red2.setAlphaF(0)
    glow.setColorAt(1, red2)
    p.setBrush(glow)
    p.drawEllipse(c, size * 0.3, size * 0.3)
    p.setBrush(RED)
    p.drawEllipse(c, 7, 7)
    p.setBrush(QColor.fromRgbF(1, 0.86, 0.82, 0.95))
    p.drawEllipse(c, 3, 3)
    p.end()
    return pix


def symbol_icon(name, size=40, alpha=0.85):
    """Simple vector icons: speaker, muted speaker, close."""
    pix = QPixmap(size, size)
    pix.fill(Qt.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    color = QColor(255, 255, 255, int(alpha * 255))
    pen = QPen(color, 2.2, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
    p.setPen(pen)
    c = size / 2
    if name == "close":
        d = size * 0.17
        p.drawLine(QPointF(c - d, c - d), QPointF(c + d, c + d))
        p.drawLine(QPointF(c + d, c - d), QPointF(c - d, c + d))
    elif name in ("sound", "muted"):
        body = QPainterPath()
        body.moveTo(c - 9, c - 4)
        body.lineTo(c - 4, c - 4)
        body.lineTo(c + 1, c - 9)
        body.lineTo(c + 1, c + 9)
        body.lineTo(c - 4, c + 4)
        body.lineTo(c - 9, c + 4)
        body.closeSubpath()
        p.fillPath(body, color)
        if name == "sound":
            p.drawArc(QRectF(c - 2, c - 5, 10, 10), -50 * 16, 100 * 16)
            p.drawArc(QRectF(c - 4, c - 9, 18, 18), -50 * 16, 100 * 16)
        else:
            p.drawLine(QPointF(c + 4, c - 4), QPointF(c + 11, c + 4))
            p.drawLine(QPointF(c + 11, c - 4), QPointF(c + 4, c + 4))
    p.end()
    return pix


class IconButton(QWidget):
    clicked = Signal()

    def __init__(self, parent, pixmap=None, side=40, icon_size=None, tip=""):
        super().__init__(parent)
        self.pixmap = pixmap
        self.side = side
        self.icon_size = icon_size or int(side * 0.85)
        self.tip = tip
        self.selected = False
        self.hover = False
        self.radius = 10
        self.setFixedSize(side, side)
        self.setMouseTracking(True)

    def set_pixmap(self, pixmap):
        self.pixmap = pixmap
        self.update()

    def set_selected(self, value):
        if value != self.selected:
            self.selected = value
            self.update()

    def enterEvent(self, event):
        self.hover = True
        self.update()

    def leaveEvent(self, event):
        self.hover = False
        self.update()

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            event.accept()
        else:
            event.ignore()

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.LeftButton:
            event.accept()
            if self.rect().contains(event.position().toPoint()):
                self.clicked.emit()
        else:
            event.ignore()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        if self.selected or self.hover:
            p.setPen(Qt.NoPen)
            p.setBrush(QColor(255, 255, 255, 46 if self.selected else 24))
            p.drawRoundedRect(QRectF(self.rect()), self.radius, self.radius)
        if self.pixmap is not None:
            s = self.icon_size
            target = QRectF((self.side - s) / 2, (self.side - s) / 2, s, s)
            p.drawPixmap(target, self.pixmap, QRectF(self.pixmap.rect()))


class Divider(QWidget):
    def __init__(self, parent):
        super().__init__(parent)
        self.setFixedSize(1, 24)

    def paintEvent(self, event):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(255, 255, 255, 46))


class InkTray(QWidget):
    """Nine ink swatches that pop up above the ink button."""

    picked = Signal(str)

    def __init__(self, parent):
        super().__init__(parent)
        self.setMouseTracking(True)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(6, 5, 6, 5)
        layout.setSpacing(2)
        self.swatches = {}
        for choice_id, title, color in INK_CHOICES:
            button = IconButton(self, pixmap=ink_dot(color) if color is not None else rainbow_dot(), side=30,
                                icon_size=28, tip=title)
            button.radius = 15
            button.clicked.connect(lambda cid=choice_id: self.picked.emit(cid))
            self.swatches[choice_id] = button
            layout.addWidget(button)
        self.adjustSize()
        self.hide()

    def refresh(self, current):
        for choice_id, button in self.swatches.items():
            button.set_selected(choice_id == current)

    def paintEvent(self, event):
        p = QPainter(self)
        rounded_panel(p, self.rect(), 14)


class HintStrip(QWidget):
    """The first-run tips shown above the toolbar."""

    def __init__(self, parent, parts):
        super().__init__(parent)
        self.setAttribute(Qt.WA_TransparentForMouseEvents)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(16, 9, 16, 9)
        layout.setSpacing(14)
        for key, text in parts:
            label = QLabel(f'<span style="color:white;font-weight:600">{key}</span>'
                           f'<span style="color:rgba(255,255,255,0.7)"> {text}</span>', self)
            label.setTextFormat(Qt.RichText)
            font = QFont()
            font.setPointSizeF(10.5)
            label.setFont(font)
            layout.addWidget(label)
        self.adjustSize()
        self.effect = QGraphicsOpacityEffect(self)
        self.effect.setOpacity(0.0)
        self.setGraphicsEffect(self.effect)
        self.animation = QPropertyAnimation(self.effect, b"opacity", self)
        self.animation.finished.connect(self._finished)
        self.on_done = None

    def fade(self, to, duration, on_done=None):
        self.animation.stop()
        self.animation.setDuration(duration)
        self.animation.setStartValue(self.effect.opacity())
        self.animation.setEndValue(to)
        self.on_done = on_done
        self.animation.start()

    def _finished(self):
        done = self.on_done
        self.on_done = None
        if done is not None:
            done()

    def paintEvent(self, event):
        p = QPainter(self)
        rounded_panel(p, self.rect(), 12)


class Toolbar(QWidget):
    pick = Signal(object)
    toggle_sound = Signal()
    exit_requested = Signal()

    def __init__(self, parent):
        super().__init__(parent)
        self.setMouseTracking(True)
        self.layout_ = QHBoxLayout(self)
        self.layout_.setContentsMargins(10, 8, 10, 8)
        self.layout_.setSpacing(6)
        self.style_buttons = {}
        self.shown_styles = []
        self.current = None
        self.revealed = False
        self.ink_open = False

        self.divider = Divider(self)
        self.layout_.addWidget(self.divider)
        self.ink_button = IconButton(self, tip="Ink colour")
        self.ink_button.clicked.connect(self._toggle_ink)
        self.layout_.addWidget(self.ink_button)
        self.sound_button = IconButton(self, pixmap=symbol_icon("sound"), icon_size=40, tip="Tap sound")
        self.sound_button.clicked.connect(self.toggle_sound.emit)
        self.layout_.addWidget(self.sound_button)
        self.exit_button = IconButton(self, pixmap=symbol_icon("close"), icon_size=40, tip="Exit (Esc)")
        self.exit_button.clicked.connect(self.exit_requested.emit)
        self.layout_.addWidget(self.exit_button)

        self.tray = InkTray(parent)
        self.tray.picked.connect(self._ink_picked)

        self.effect = QGraphicsOpacityEffect(self)
        self.effect.setOpacity(0.0)
        self.setGraphicsEffect(self.effect)
        self.animation = QPropertyAnimation(self.effect, b"opacity", self)
        self.animation.setEasingCurve(QEasingCurve.OutCubic)
        self.animation.finished.connect(self._animation_done)
        self.hide()
        self.rebuild_styles()
        self.refresh_ink()

    # -- layout ----------------------------------------------------------------

    def frame(self):
        rect = QRect(self.geometry())
        if self.ink_open and self.tray.isVisible():
            rect = rect.united(self.tray.geometry())
        return rect

    def place(self, bottom):
        """Centre the toolbar horizontally with its bottom edge at `bottom` (overlay coordinates)."""
        self.adjustSize()
        parent = self.parentWidget()
        x = (parent.width() - self.width()) // 2
        y = bottom - self.height()
        self.move(x, y)
        self._place_tray()

    def _place_tray(self):
        self.tray.adjustSize()
        centre = self.ink_button.mapTo(self.parentWidget(), self.ink_button.rect().center())
        self.tray.move(centre.x() - self.tray.width() // 2, self.y() - 8 - self.tray.height())

    def rebuild_styles(self):
        styles = list(prefs().pinned_styles)
        if self.current is not None and self.current not in styles:
            styles.append(self.current)
        if styles == self.shown_styles:
            return
        self.shown_styles = styles
        for button in self.style_buttons.values():
            self.layout_.removeWidget(button)
            button.deleteLater()
        self.style_buttons = {}
        for i, style in enumerate(styles):
            pixmap = laser_icon() if style.is_laser else HandAsset.thumbnail(style)
            button = IconButton(self, pixmap=pixmap, icon_size=36, tip=style.title)
            button.clicked.connect(lambda s=style: self.pick.emit(s))
            self.style_buttons[style] = button
            self.layout_.insertWidget(i, button)
        self._highlight()
        self._resize_keeping_centre()

    def _resize_keeping_centre(self):
        centre_x = self.x() + self.width() / 2
        bottom = self.y() + self.height()
        self.adjustSize()
        self.move(int(centre_x - self.width() / 2), bottom - self.height())
        self._place_tray()

    def select(self, style):
        self.current = style
        self.rebuild_styles()
        self._highlight()
        self.refresh_ink()

    def _highlight(self):
        for style, button in self.style_buttons.items():
            button.set_selected(style == self.current)

    def set_sound_on(self, on):
        self.sound_button.set_pixmap(symbol_icon("sound" if on else "muted", alpha=0.85 if on else 0.45))

    # -- ink -------------------------------------------------------------------

    def _toggle_ink(self):
        self.set_ink_open(not self.ink_open)

    def set_ink_open(self, open_):
        if open_ == self.ink_open:
            return
        self.ink_open = open_
        if open_:
            self._place_tray()
            self.tray.raise_()
            self.tray.show()
        else:
            self.tray.hide()
        self.refresh_ink()

    def _ink_picked(self, choice_id):
        prefs().set("inkChoice", choice_id)
        self.set_ink_open(False)

    def refresh_ink(self):
        style = self.current or prefs().pointer_style
        self.ink_button.set_pixmap(ink_dot(ink_color_for(prefs().ink_choice, style)))
        self.ink_button.set_selected(self.ink_open)
        hidden = not prefs().show_ink_button
        if self.ink_button.isHidden() != hidden:
            self.ink_button.setVisible(not hidden)
            if hidden:
                self.set_ink_open(False)
            self._resize_keeping_centre()
        self.tray.refresh(prefs().ink_choice)

    # -- reveal ----------------------------------------------------------------

    def set_revealed(self, value):
        if value == self.revealed:
            return
        self.revealed = value
        if not value:
            self.set_ink_open(False)
        self.animation.stop()
        self.animation.setDuration(150 if value else 350)
        self.animation.setStartValue(self.effect.opacity())
        self.animation.setEndValue(1.0 if value else 0.0)
        if value:
            self.show()
            self.raise_()
        self.animation.start()

    def _animation_done(self):
        if not self.revealed:
            self.hide()

    def hide_now(self):
        self.revealed = False
        self.animation.stop()
        self.effect.setOpacity(0.0)
        self.set_ink_open(False)
        self.hide()

    def paintEvent(self, event):
        p = QPainter(self)
        rounded_panel(p, self.rect(), 16)
