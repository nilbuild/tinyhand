"""Thin ctypes bridge to LayerShellQt, so the overlay can sit above every window and panel.

LayerShellQt has no Python bindings. Its setters take plain integers, so calling the
C++ symbols directly is safe on the x86_64 and aarch64 ABIs.
"""

import ctypes
import ctypes.util

ANCHOR_TOP = 1
ANCHOR_BOTTOM = 2
ANCHOR_LEFT = 4
ANCHOR_RIGHT = 8
ANCHOR_ALL = ANCHOR_TOP | ANCHOR_BOTTOM | ANCHOR_LEFT | ANCHOR_RIGHT

LAYER_BACKGROUND = 0
LAYER_BOTTOM = 1
LAYER_TOP = 2
LAYER_OVERLAY = 3

KEYBOARD_NONE = 0
KEYBOARD_EXCLUSIVE = 1
KEYBOARD_ON_DEMAND = 2

SCREEN_FROM_QWINDOW = 0
SCREEN_FROM_COMPOSITOR = 1

_lib = None
_symbols = {}


def _load():
    global _lib
    if _lib is not None:
        return _lib
    for name in ("libLayerShellQtInterface.so.6", ctypes.util.find_library("LayerShellQtInterface")):
        if not name:
            continue
        try:
            _lib = ctypes.CDLL(name)
            break
        except OSError:
            continue
    if _lib is None:
        return None
    table = {
        "get": ("_ZN12LayerShellQt6Window3getEP7QWindow", ctypes.c_void_p, [ctypes.c_void_p]),
        "set_layer": ("_ZN12LayerShellQt6Window8setLayerENS0_5LayerE", None, [ctypes.c_void_p, ctypes.c_uint]),
        "set_anchors": ("_ZN12LayerShellQt6Window10setAnchorsE6QFlagsINS0_6AnchorEE", None,
                        [ctypes.c_void_p, ctypes.c_uint]),
        "set_keyboard": ("_ZN12LayerShellQt6Window24setKeyboardInteractivityENS0_21KeyboardInteractivityE", None,
                         [ctypes.c_void_p, ctypes.c_uint]),
        "set_exclusive_zone": ("_ZN12LayerShellQt6Window16setExclusiveZoneEi", None, [ctypes.c_void_p, ctypes.c_int]),
        "set_screen_configuration": ("_ZN12LayerShellQt6Window22setScreenConfigurationENS0_19ScreenConfigurationE",
                                     None, [ctypes.c_void_p, ctypes.c_uint]),
    }
    for key, (symbol, restype, argtypes) in table.items():
        try:
            fn = getattr(_lib, symbol)
        except AttributeError:
            _lib = None
            return None
        fn.restype = restype
        fn.argtypes = argtypes
        _symbols[key] = fn
    return _lib


def available():
    return _load() is not None


def configure(qwindow, layer=LAYER_OVERLAY, anchors=ANCHOR_ALL, keyboard=KEYBOARD_NONE):
    """Turn a not-yet-shown QWindow into a layer surface with the given layer and anchors."""
    if _load() is None:
        return False
    import shiboken6

    ptr = shiboken6.getCppPointer(qwindow)[0]
    window = _symbols["get"](ptr)
    if not window:
        return False
    _symbols["set_layer"](window, layer)
    _symbols["set_anchors"](window, anchors)
    _symbols["set_keyboard"](window, keyboard)
    _symbols["set_exclusive_zone"](window, -1)
    _symbols["set_screen_configuration"](window, SCREEN_FROM_QWINDOW)
    return True
