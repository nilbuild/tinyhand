"""One transparent window per screen that draws the hand, takes the clicks, and hosts the toolbar."""

import time

from PySide6.QtCore import QPointF, QRect, QRectF, QTimer, Qt
from PySide6.QtGui import QGuiApplication, QPainter, QRegion
from PySide6.QtWidgets import QWidget

from . import layershell
from .arm import ArmRenderer
from .ink import Ink
from .prefs import ink_color_for, prefs
from .toolbar import HintStrip, Toolbar

NO_INPUT = QRegion(QRect(-10, -10, 1, 1))

DEBUG = bool(__import__("os").environ.get("TINYHAND_DEBUG"))
COUNTS = {"paint": 0, "tick": 0, "aim": 0, "move": 0}


def _debug_report():
    if DEBUG:
        print("counts/s", dict(COUNTS), flush=True)
        for key in COUNTS:
            COUNTS[key] = 0


_debug_timer = None


def _start_debug():
    global _debug_timer
    if DEBUG and _debug_timer is None:
        _debug_timer = QTimer()
        _debug_timer.timeout.connect(_debug_report)
        _debug_timer.start(1000)


class Overlay(QWidget):
    def __init__(self, controller, screen):
        super().__init__(None)
        _start_debug()
        self.controller = controller
        self.target_screen = screen
        self.wayland = QGuiApplication.platformName().startswith("wayland")
        if self.wayland:
            self.setWindowFlags(Qt.FramelessWindowHint)
        else:
            self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.X11BypassWindowManagerHint
                                | Qt.Tool)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_NoSystemBackground)
        self.setMouseTracking(True)
        self.setCursor(Qt.BlankCursor)

        self.arm = ArmRenderer()
        self.ink = Ink()
        self.toolbar = Toolbar(self)
        self.toolbar.pick.connect(controller.pick)
        self.toolbar.toggle_sound.connect(controller.toggle_sound)
        self.toolbar.exit_requested.connect(controller.exit)
        self.hint = None
        self.down_point = None
        self.reveal_until = 0.0
        self.pass_through = False
        self.last_mouse = None

        self.tick_timer = QTimer(self)
        self.tick_timer.setInterval(8)
        self.tick_timer.timeout.connect(self._tick)
        self.fade_timer = QTimer(self)
        self.fade_timer.setInterval(33)
        self.fade_timer.timeout.connect(self._fade_tick)

        self.winId()
        handle = self.windowHandle()
        handle.setScreen(screen)
        if self.wayland:
            layershell.configure(handle, layer=layershell.LAYER_OVERLAY, anchors=layershell.ANCHOR_ALL,
                                 keyboard=layershell.KEYBOARD_NONE)
        else:
            self.setGeometry(screen.geometry())
        self.apply_prefs()

    # -- geometry ------------------------------------------------------------

    @property
    def ink_width(self):
        return max(3.0, self.height() * 0.0055)

    def toolbar_bottom(self):
        """Where the toolbar's bottom edge goes: 14 px above the panel, like above the Dock on macOS."""
        screen = self.target_screen
        available = screen.availableGeometry()
        full = screen.geometry()
        bottom = available.bottom() - full.top() + 1
        return min(self.height(), bottom) - 14

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.arm.set_size(self.width(), self.height(), self.devicePixelRatioF())
        self.toolbar.place(self.toolbar_bottom())
        self._place_hint()
        self.clear_ink()
        if self.last_mouse is not None:
            self.aim(self.last_mouse)

    # -- preferences ---------------------------------------------------------

    def apply_prefs(self):
        p = prefs()
        self.arm.hand_len_frac = p.pointer_size
        self.arm.show_shadow = p.show_shadow
        self.ink.fade_seconds = p.fade_seconds
        self.ink.color = ink_color_for(p.ink_choice, self.arm.style)
        self.arm.pose = None
        self.toolbar.rebuild_styles()
        self.toolbar.refresh_ink()
        self.toolbar.set_sound_on(p.sound_on_for(self.arm.style))
        if self.last_mouse is not None:
            self.aim(self.last_mouse)
        self.update()

    def set_style(self, style):
        old = self.arm.bounds()
        self.arm.set_style(style)
        self.ink.color = ink_color_for(prefs().ink_choice, self.arm.style)
        self.toolbar.select(self.arm.style)
        self.toolbar.set_sound_on(prefs().sound_on_for(self.arm.style))
        self._update_rect(old)
        if self.last_mouse is not None:
            self.aim(self.last_mouse)

    # -- pointer -------------------------------------------------------------

    def set_hand_hidden(self, hidden):
        if hidden == self.arm.hidden:
            return
        if hidden:
            self.release()
        self.arm.hidden = hidden
        self._update_rect(self.arm.bounds())

    def set_pass_through(self, value):
        """Let clicks fall through to the windows beneath (used by step-aside)."""
        self.pass_through = value
        handle = self.windowHandle()
        if handle is None:
            return
        if self.wayland:
            handle.setMask(NO_INPUT if value else QRegion())
        else:
            self.setWindowFlag(Qt.WindowTransparentForInput, value)
            self.show()
        if value:
            self.toolbar.hide_now()
        self.set_hand_hidden(value)

    def aim(self, pos):
        COUNTS["aim"] += 1
        self.last_mouse = QPointF(pos)
        old = self.arm.bounds()
        if self.arm.aim(pos):
            self._update_rect(old.united(self.arm.bounds()))
        self._update_zones(pos)
        if (self.arm.is_settling or self.arm.held) and not self.tick_timer.isActive():
            self.tick_timer.start()

    def _tick(self):
        COUNTS["tick"] += 1
        if self.last_mouse is None:
            self.tick_timer.stop()
            return
        old = self.arm.bounds()
        if self.arm.aim(self.last_mouse):
            self._update_rect(old.united(self.arm.bounds()))
        if not self.arm.is_settling and not self.arm.held:
            self.tick_timer.stop()

    def _update_rect(self, rect):
        if rect.isNull() or rect.isEmpty():
            return
        self.update(rect.toAlignedRect().adjusted(-2, -2, 2, 2))

    def reveal_for(self, seconds):
        """Show the toolbar for a while, then fall back to the hover rule."""
        self.reveal_until = time.monotonic() + seconds
        self.toolbar.set_revealed(True)
        QTimer.singleShot(int(seconds * 1000) + 50, self._recheck_zones)

    def _recheck_zones(self):
        if self.last_mouse is not None:
            self._update_zones(self.last_mouse)
        elif time.monotonic() >= self.reveal_until:
            self.toolbar.set_revealed(False)

    def _update_zones(self, mouse):
        frame = self.toolbar.frame()
        near_rect = frame.adjusted(-80, -90 - 10, 80, 10)
        near = near_rect.contains(mouse.toPoint())
        drawing = self.ink.is_drawing
        self.toolbar.set_revealed(not drawing and (near or time.monotonic() < self.reveal_until))

    # -- mouse -----------------------------------------------------------------

    def enterEvent(self, event):
        self.controller.pointer_entered(self)
        self.set_hand_hidden(self.pass_through)
        self.aim(event.position())

    def mouseMoveEvent(self, event):
        COUNTS["move"] += 1
        pos = event.position()
        self.aim(pos)
        if self.down_point is not None:
            self.drag(pos)

    def mousePressEvent(self, event):
        button = event.button()
        if button == Qt.LeftButton:
            self.press(event.position())
            return
        name = "right" if button == Qt.RightButton else "middle" if button == Qt.MiddleButton else ""
        if name and name == prefs().step_aside_button:
            self.controller.step_aside()

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.release()

    def press(self, pos):
        self.arm.press()
        self.arm.held = True
        self.down_point = QPointF(pos)
        self.hide_hint()
        self.controller.tapped(self)
        self.aim(pos)

    def drag(self, pos):
        start = self.down_point
        if start is None:
            return
        if not self.ink.is_drawing:
            if (pos - start).manhattanLength() < 4:
                return
            self._update_rect(self.ink.begin(start, self.ink_width))
            self._update_zones(pos)
        segment = self.ink.extend(pos)
        if segment is not None:
            self._update_rect(segment)

    def release(self):
        if self.down_point is None and not self.arm.held:
            return
        self.arm.held = False
        self.down_point = None
        self.ink.end()
        if self.ink.has_pending_fade() and not self.fade_timer.isActive():
            self.fade_timer.start()
        if self.last_mouse is not None:
            self.aim(self.last_mouse)

    # -- ink -------------------------------------------------------------------

    def clear_ink(self):
        for rect in self.ink.clear():
            self._update_rect(rect)
        self.fade_timer.stop()

    def _fade_tick(self):
        now = time.monotonic()
        for stroke in self.ink.strokes:
            if self.ink.is_fading(stroke, now):
                self._update_rect(stroke.bounds)
        for rect in self.ink.prune(now):
            self._update_rect(rect)
        if not self.ink.has_pending_fade():
            self.fade_timer.stop()

    # -- hint ------------------------------------------------------------------

    def show_hint(self, parts, seconds):
        self.hide_hint()
        self.hint = HintStrip(self, parts)
        self._place_hint()
        self.hint.show()
        self.hint.raise_()
        self.hint.fade(1.0, 200)
        QTimer.singleShot(int(seconds * 1000), self.hide_hint)

    def _place_hint(self):
        if self.hint is None:
            return
        x = (self.width() - self.hint.width()) // 2
        y = self.toolbar.y() - 12 - self.hint.height()
        self.hint.move(x, y)

    def hide_hint(self):
        hint = self.hint
        if hint is None:
            return
        self.hint = None
        hint.fade(0.0, 300, hint.deleteLater)

    # -- painting --------------------------------------------------------------

    def paintEvent(self, event):
        COUNTS["paint"] += 1
        painter = QPainter(self)
        clip = QRectF(event.rect())
        self.ink.paint(painter, clip)
        if self.arm.bounds().intersects(clip):
            self.arm.paint(painter)
        painter.end()
